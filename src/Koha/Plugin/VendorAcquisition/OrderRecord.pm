# Copyright (C) 2021  Andreas Jonsson <andreas.jonsson@kreablo.se>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Koha::Plugin::VendorAcquisition::OrderRecord;

use C4::XSLT;
use Data::Dumper;
use C4::Matcher;
use C4::Biblio qw( GetMarcBiblio AddBiblio GetBiblioData );
use Koha::Plugin::VendorAcquisition::OrderItem;
use MARC::File::XML;

sub new {
    my ( $class, $plugin, $lang, $order ) = @_;

    my $self = bless( {}, $class );

    $self->{errors} = [];
    $self->{warnings} = [];
    $self->{plugin} = $plugin;
    $self->{lang} = $lang;
    $self->{order} = $order;
    $self->{items} = [];

    return $self;
}

sub new_from_json {
    my ( $class, $plugin, $lang, $order, $item_data ) = @_;

    my $self = __PACKAGE__->new( $plugin, $lang, $order );

    $self->update_from_json( $item_data );

    return $self;
}

sub new_from_hash {
    my ( $class, $plugin, $lang, $order, $data ) = @_;

    my $self = __PACKAGE__->new( $plugin, $lang, $order );

    for my $field (fields()) {
        $self->{$field} = $data->{$field};
    }

    my $record;
    eval {
        $MARC::File::XML::_load_args{BinaryEncoding} = 'utf-8';
        $MARC::File::XML::_load_args{RecordFormat} = 'USMARC';

        $record = MARC::Record::new_from_xml($self->{record});
    };

    if ($@) {
        $self->_err("Failed to parse MARC record: $@");
        return;
    }

    $self->{record} = $record;

    $self->prepare_record;

    if (defined $self->{record_id}) {
        $self->load_items;
    }

    return $self;
}

sub prepare_record {
    my $self = shift;

    $self->{record_display} = XSLTParse4Display(undef, $self->{record}, 'XSLTDetailsDisplay', 0, 0, '', 'default', $self->{lang}, undef);

    for my $d ($self->matcher->get_matches($self->{record}, 10)) {
        my $duplicate = {
            biblionumber => $d->{record_id},
            score => $d->{score},
            selected => 0
        };
        my $record = GetMarcBiblio({ biblionumber => $d->{record_id} });

        if (!$record) {
            $self->_warn("Failed to load matching record " . $d->{record_id});
        }

        $duplicate->{record_display} = XSLTParse4Display(undef, $self->{record}, 'XSLTDetailsDisplay', 0, 0, '', 'default', $self->{lang}, undef);

        if ($self->{biblionumber} eq $duplicate->{biblionumber}) {
            $duplicate->{selected} = 1;
        }

        push @{$self->{duplicates}}, $duplicate;
    }
}

sub matcher {
    my $self = shift;

    my $record_match_rule = $self->{plugin}->retrieve_data('record_match_rule');

    my $matcher = C4::Matcher->fetch( $record_match_rule );

    return $matcher;
}

sub update_from_json {
    my ($self, $item_data) = @_;

    $self->{item_data} = $item_data;
    $self->validate_item_data;

    if (defined $self->{record_id}) {
        $self->load_items;
    }

    if (scalar(@{$self->{duplicates}}) > 0) {
        $self->{merge_biblionumber} = $self->{duplicates}->[0]->{biblionumber};
    }

    for (my $i = scalar(@{$self->{items}}); $i < $self->{quantity}; $i++) {
        my $item = Koha::Plugin::VendorAcquisition::OrderItem->new($self->{plugin}, $self->{lang}, $self);

        $item->initiate;

        push @{$self->{items}}, $item;
    }

    for (my $i = $self->{quantity}; $i < scalar(@{$self->{items}}); $i++) {
        $self->{items}->[$i]->delete;
    }
    splice @{$self->{items}}, $self->{quantity};
}

sub update_from_cgi {
    my ($self, $cgi) = @_;

    my $biblionumber = $cgi->param('duplicate-biblionumber-' . $self->{record_id});

    if (defined $biblionumber && $biblionumber ne '') {
        $self->{merge_biblionumber} = $biblionumber;
    } else {
        $self->{merge_biblionumber} = undef;
    }

    for my $item (@{$self->{items}}) {
        $item->update_from_cgi($cgi);
    }
}

sub fields {
    return qw (record_id author barcode isbn  callnumber callnumber_standard estimated_delivery_date biblioid biblioid_standard note record currency price price_inc_vat price_rrp publisher quantity title vat year biblionumber ordernumber merge_biblionumber);
}

sub load_record_id {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    my $recordtable = $self->table_naming('record');

    my $sql = "SELECT record_id FROM `$recordtable` WHERE order_id = ? AND biblioid = ? AND biblioid_standard = ?";

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute($self->{order}->{order_id}, $self->{biblioid}, $self->{biblioid_standard});

    if (!$rv) {
        $self->_err("Failed to load record_id: " . $dbh->errstr);
        return;
    }

    my $row = $sth->fetchrow_hashref;
    if ($row) {
        $self->{record_id} = $row->{record_id};
    }
}

sub store {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    my $recordtable = $self->table_naming('record');

    my $sql;
    my @binds = ();

    if (defined $self->{record_id}) {
        $sql = "UPDATE `$recordtable` ";
    } else {
        $sql = "INSERT INTO `$recordtable` ";
    }

    $sql .= <<'EOF';
SET order_id = ?,
    author = ?,
    barcode = ?,
    isbn = ?,
    callnumber = ?,
    callnumber_standard = ?,
    estimated_delivery_date = ?,
    biblioid = ?,
    biblioid_standard = ?,
    note = ?,
    record = ?,
    currency = ?,
    price = ?,
    price_inc_vat = ?,
    price_rrp = ?,
    publisher = ?,
    quantity = ?,
    title = ?,
    vat = ?,
    year = ?,
    biblionumber = ?,
    ordernumber = ?,
    merge_biblionumber = ?
EOF


        @binds = (
            $self->{order}->{order_id},
            $self->{author},
            $self->{barcode},
            $self->{isbn},
            $self->{callnumber},
            $self->{callnumber_standard},
            $self->{estimated_delivery_date},
            $self->{biblioid},
            $self->{biblioid_standard},
            $self->{note},
            $self->{record}->as_xml_record,
            $self->{currency},
            $self->{price},
            $self->{price_inc_vat},
            $self->{price_rrp},
            $self->{publisher},
            $self->{quantity},
            $self->{title},
            $self->{vat},
            $self->{year},
            $self->{biblionumber},
            $self->{ordernumber},
            $self->{merge_biblionumber}
        );

    if (defined $self->{record_id}) {
        $sql .= " WHERE record_id = ?";
        push @binds, $self->{record_id};
    }

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute(@binds);

    if (!$rv) {
        $self->_err("Failed to save record: " . $dbh->errstr);
        goto FAIL;
    }

    if (!defined $self->{record_id}) {
        $self->{record_id} = $dbh->last_insert_id(undef, undef, $recordtable, undef);
    }

    for my $item (@{$self->{items}}) {
        if (!$item->store) {
            goto FAIL;
        }
    }

    $self->delete_items;

    return 1;

  FAIL:
    return 0;
}

sub validate_item_data {
    my $self = shift;

    my $record;

    my $item_data = $self->{item_data};

    my %ef = (
        Author => 1,
        Currency => 1,
        ISBN => 1,
        ItemBarcode => 1,
        ItemCallnumber => 1,
        ItemCallnumberStandard => 1,
        ItemEstimatedDeliveryDate => 1,
        ItemID => 2,
        ItemIDStandard => 2,
        ItemNote => 1,
        MARCRecord => 2,
        MARCRecordFormat => 2,
        Price => 1,
        PriceIncVAT => 1,
        PriceRRP => 1,
        Publisher => 1,
        Quantity => 2,
        Title => 1,
        VAT => 1,
        Year => 1
    );

    for my $field (keys %$item_data) {
        if (defined $ef{$field} && $ef{$field} > 0) {
            $ef{$field} = 0;
        } else {
            if (!defined $ef{$field}) {
                $self->_warn("Unexpected item field in order data: '$field'");
            }
        }
    }

    for my $field (keys %ef) {
        if ($ef{$field} == 2) {
            $self->_err("Required item field '" . $field . "' is missing.");
        } elsif ($ef{$field} == 1) {
            $self->_warn("Optional item field '" . $field . "' is missing.");
        }
    }

    my $format = lc $item_data->{MARCRecordFormat};

    if ($format eq 'marc21') {
        eval {
            $record = MARC::Record::new_from_usmarc($item_data->{MARCRecord});
        };
    } elsif ($format eq 'marcxml') {
        eval {
            $MARC::File::XML::_load_args{BinaryEncoding} = 'utf-8';
            $MARC::File::XML::_load_args{RecordFormat} = 'USMARC';

            $record = MARC::Record::new_from_xml($item_data->{MARCRecord});
        };
    } else {
        $self->_err("Unknown marc record format: $format");
        return;
    }

    if ($@) {
        $self->_err("Failed to parse MARC record: $@");
        return;
    }

    $self->{author} = $self->data('Author');
    $self->{currency} = $self->data('Currency');
    $self->{isbn} = $self->data('ISBN');
    $self->{barcode} = $self->data('ItemBarcode');
    $self->{callnumber} = $self->data('ItemCallnumber');
    $self->{callnumber_standard} = $self->data('ItemCallnumberStandard');
    $self->{note} = $self->data('ItemNote');
    $self->{price} = $self->data('Price');
    $self->{price_inc_vat} = $self->data('PriceIncVAT');
    $self->{price_rrp} = $self->data('PriceRRP');
    $self->{publisher} = $self->data('Publisher');
    $self->{quantity} = $self->data('Quantity');
    $self->{title} = $self->data('Title');
    $self->{vat} = $self->data('VAT');
    $self->{year} = $self->data('Year');
    $self->{biblioid} = $self->data('ItemID');
    $self->{biblioid_standard} = $self->data('ItemIDStandard');
    $self->{biblionumber} = undef;

    if (!$self->{quantity} =~ /^\d+$/) {
        $self->_err("Quantity is not an integer!");
        return;
    }

    $self->{record} = $record;
    $self->prepare_record;

    $self->load_record_id;

    if (defined $self->{record_id}) {
        $self->load_items;
    }
}

sub load_items {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    my $itemtable = $self->table_naming('item');

    $self->{items} = [];

    my $sql = "SELECT `" . join('`, `', Koha::Plugin::VendorAcquisition::OrderItem->fields) .  "` FROM `$itemtable` WHERE record_id = ?";

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute($self->{record_id});

    if (!$rv) {
        $self->_err("Failed to load items: " . $dbh->errstr);
        return;
    }

    while (my $row = $sth->fetchrow_hashref) {
        my $item = Koha::Plugin::VendorAcquisition::OrderItem->new_from_hash($self->{plugin}, $self->{lang}, $self, $row);

        push @{$self->{items}}, $item;
    }

}

sub delete_items {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    my $itemtable = $self->table_naming('item');

    my $sql = "DELETE FROM `$itemtable` WHERE record_id = ? ";

    my @binds = ($self->{record_id});

    for my $record (@{$self->{items}}) {
        $sql .= " AND item_id != ?";
        push @binds, $record->{item_id};
    }

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute(@binds);

    if (!$rv) {
        $self->_err("Failed to delete items: " . $dbh->errstr);
    }
}


sub process {
    my $self = shift;

    my $biblioitemnumber;

    if (defined $self->{merge_biblionumber}) {
        $self->{biblionumber} = $self->{merge_biblionumber};
    }
    if (!defined $self->{biblionumber} || $self->{biblionumber} eq '') {
        my $biblionumber;

        eval {
            ( $biblionumber, $biblioitemnumber ) = AddBiblio( $self->{record}, '' );
        };

        if ($@) {
            $self->error("Failed to add record: $@");
            return 0;
        }

        $self->{biblionumber} = $biblionumber;
    }  else {
        $biblioitemnumber = GetBiblioData($self->{biblionumber})->{biblioitemnumber};
    }

    for my $item (@{$self->{items}}) {
        if (!$item->process($biblioitemnumber)) {
            return 0;
        }
    }

    return 1;
}


sub _err {
    my ($self, $msg) = @_;

    push @{$self->{errors}}, $msg;
}

sub _warn {
    my ($self, $msg) = @_;

    push @{$self->{warnings}}, $msg;
}

sub errors {
    my $self = shift;

    return @{$self->{errors}};
}

sub all_errors {
    my $self = shift;

    my @errors = @{$self->{errors}};

    for my $record (@{$self->{records}}) {
        push @errors, $record->errors;
        for my $item ( @{$record->{items}} ) {
            push @errors, $item->errors;
        }
    }

    return @errors;
}

sub warnings {
    my $self = shift;

    return @{$self->{warnings}};
}

sub valid {
    my $self = shift;

    return scalar($self->errors) == 0;
}

sub table_naming {
    my $self = shift;

    return $self->{plugin}->get_qualified_table_name($_[0]);
}

sub data {
    my ($self, $field) = @_;

    return $self->{item_data}->{$field};
}

1;
