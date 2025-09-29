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

package Koha::Plugin::VendorAcquisition::OrderItem;

use strict;
use Koha::Item;
use C4::Context;

sub new {
    my ( $class, $plugin, $lang, $record ) = @_;

    my $self = bless( {}, $class );

    $self->{errors} = [];
    $self->{warnings} = [];
    $self->{plugin} = $plugin;
    $self->{lang} = $lang;
    $self->{record} = $record;

    $self->{itemcallnumber} = $record->{callnumber};
    $self->{price} = $record->{price};

    $self->{item_id} = 'tmp' . scalar(@{$record->{items}});

    return $self;
}

sub new_from_hash {
    my ( $class, $plugin, $lang, $record, $data ) = @_;

    my $self = __PACKAGE__->new( $plugin, $lang, $record );

    for my $field (fields()) {
        $self->{$field} = $data->{$field};
    }

    return $self;
}

sub update_from_cgi {
    my ($self, $cgi) = @_;

    for my $field (qw(notforloan homebranch holdingbranch location itemnumber itemtype ccode itemcallnumber budget_id)) {
        my $val = $cgi->param($field . '-' . $self->{item_id});
        if (defined $val && ($field ne 'budget_id' || $val ne '')) {
            $self->{$field} = $val;
        }
    }
}

sub _perm_id {
    my $id = shift;

    return (defined $id) && ! ($id =~ /^tmp/);
}

sub initiate {
    my $self = shift;

    my $rule = $self->{record}->{order}->default_values;

    if (defined $rule) {
        for my $field ('customer_number', 'notforloan', 'homebranch', 'holdingbranch', 'location', 'ccode', 'itemtype') {
            if (($field eq 'homebranch' || $field eq 'holdingbranch') && (!defined $rule->{$field} || $rule->{$field} eq '')) {
                $self->{$field} = C4::Context->userenv->{'branch'};
            } else {
                $self->{$field} = $rule->{$field};
            }
            if ($field eq 'notforloan' && (!defined $rule->{$field} || $rule->{$field} eq '')) {
                $self->{$field} = 0;
            }
        }
    }
}

sub store {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    my $itemtable = $self->table_naming('item');

    my $sql;
    my @binds = ();

    if (_perm_id($self->{item_id})) {
        $sql = "UPDATE `$itemtable` ";
    } else {
        $sql = "INSERT INTO `$itemtable` ";
    }

    $sql .= <<'EOF';
SET record_id = ?,
    notforloan = ?,
    homebranch = ?,
    holdingbranch = ?,
    location = ?,
    itemtype = ?,
    ccode = ?,
    itemnumber = ?,
    barcode = ?,
    itemcallnumber = ?,
    price = ?,
    budget_id = ?,
    ordernumber = ?
EOF
    @binds = (
        $self->{record}->{record_id},
        defined($self->{notforloan}) ? $self->{notforloan} : 0,
        $self->{homebranch},
        $self->{holdingbranch},
        $self->{location},
        $self->{itemtype},
        $self->{ccode},
        $self->{itemnumber},
        $self->{barcode},
        $self->{itemcallnumber},
        $self->{price},
        $self->{budget_id},
        $self->{ordernumber}
        );

    if (_perm_id($self->{item_id})) {
        $sql .= ' WHERE item_id = ?';
        push @binds, $self->{item_id};
    }

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute(@binds);

    if (!$rv) {
        $self->_err("Failed to save item: " . $dbh->errstr);
    }

    if (!_perm_id($self->{item_id})) {
        $self->{item_id} = $dbh->last_insert_id(undef, undef, $itemtable, undef);
    }
}

sub delete {
    my $self = shift;

    return if !_perm_id($self->{item_id});

    my $dbh   = C4::Context->dbh;

    my $itemtable = $self->table_naming('item');

    my $sql = "DELETE FROM `$itemtable` WHERE item_id = ?";

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute($self->{item_id});

    if (!$rv) {
        $self->_err("Failed to delete item: " . $dbh->errstr);
    }
}

sub process {
    my $self = shift;
    my $biblioitemnumber = shift;

    my $barcode = $self->{barcode};

    if (defined $barcode) {
	my @items = Koha::Items->find({
	    barcode => $barcode
        });
	if (@items) {
	    $barcode = undef;
	}
    }

    my $main_price = $self->{record}->{$self->{plugin}->retrieve_data('price_including_vat') ? 'price_inc_vat' : 'price'};

    my $iteminfo = {
        biblionumber => $self->{record}->{biblionumber},
        biblioitemnumber => $biblioitemnumber,
        homebranch => $self->{homebranch},
        holdingbranch => $self->{holdingbranch},
        notforloan => defined($self->{notforloan}) ? $self->{notforloan} : 0,
        location => $self->{location},
        itype => $self->{itemtype},
        ccode => $self->{ccode},
        barcode => $barcode,
        itemcallnumber => $self->{itemcallnumber},
        price => $main_price
    };

    if ($self->{plugin}->retrieve_data('fill_out_replacementprice')) {
        $iteminfo->{replacementprice} = $self->{record}->{'price_inc_vat'};
    }

    my $item = Koha::Item->new($iteminfo)->store;

    if (!defined $item) {
        $self->_err("Failed to generate koha item.");
        return 0;
    }

    $self->{itemnumber} = $item->itemnumber;

    return 1;
}

sub fields {
    return qw(item_id record_id notforloan homebranch holdingbranch location itemtype ccode itemnumber barcode budget_id ordernumber);
}

sub _err {
    my ($self, $msg, $nopush) = @_;

    unless ($nopush) {
        push @{$self->{errors}}, $msg;
    }

    $self->{record}->_err($msg, 1);
}

sub _warn {
    my ($self, $msg, $nopush) = @_;

    unless ($nopush) {
        push @{$self->{warnings}}, $msg;
    }

    $self->{record}->_warn("$msg", 1);
}

sub errors {
    my $self = shift;

    return @{$self->{errors}};
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


1;
