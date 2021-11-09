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

package Koha::Plugin::VendorAcquisition::Order;

use strict;
use JSON;
use DateTime;
use DateTime::Format::Strptime;
use DateTime::TimeZone::UTC;
use Ref::Util qw( is_arrayref );
use MARC::Record;
use Koha::DateUtils qw( output_pref dt_from_string );
use Koha::Plugin::VendorAcquisition::OrderRecord;
use Koha::Acquisition::Order;
use Koha::Acquisition::Basket;
use Koha::Acquisition::Baskets;
use MIME::Base64;
use Encode;
use utf8;

sub new {
    my ( $class, $plugin, $lang, $json_text ) = @_;

    my $self = bless( {}, $class );

    $self->{plugin} = $plugin;
    $self->{errors} = [];
    $self->{warnings} = [];
    $self->{lang} = $lang;
    $self->{records} = [];
    $self->{is_new} = 0;
    $self->{record_ids} = {};

    $self->die_on_error(0);
    
    return $self;
}

sub new_from_json {
    my ( $class, $plugin, $lang, $json_text ) = @_;

    my $json = JSON->new;
    my $data;

    my $self = __PACKAGE__->new( $plugin, $lang );

    $self->{json} = $json_text;
    $self->{date_format} = DateTime::Format::Strptime->new(
        pattern => '%FT%H:%M:%SZ',
        time_zone => DateTime::TimeZone::UTC->new->name,
        locale => 'C',
        on_error => 'croak'
        );

    eval {
        $data = $json->decode($json_text);
    };

    if ($@) {
        eval {
            my $decoded = Encode::decode('UTF-8', decode_base64($json_text));
            $data = $json->decode($decoded);
        };
    }

    if ($@) {
        $self->_err('Could not parse JSON data: ' . $@);
    } else {
       $self->{data} = $data;
 

       $self->validate();
       $self->validate_items();
       if ($self->valid()) {
           $self->load();
           $self->validate();
           $self->validate_items();
       }

       my $rule = $self->default_values;

       if (defined $rule->{budget_id}) {
           $self->{budget_id} = $rule->{budget_id};
       }
    }

    $self->record_duplicates;

    return $self;
}

sub update_from_cgi {
    my ($self, $cgi) = @_;

    my $basketno;

    my $basketType = $cgi->param('basket-type');

    if ($basketType eq 'existing') {
        $basketno = $cgi->param('order-basket');
    } elsif ($basketType eq 'new-order' || $basketType eq 'new') {
        my $basketname = $basketType eq 'new-order' ? $self->{order_number} : $cgi->param('order-basketname');
        my @baskets = Koha::Acquisition::Baskets->search({ basketname => $basketname });
        if ( scalar(@baskets) > 0) {
            my $basket = $baskets[0];
            $basketno = $basket->basketno;
        } else {
	    my $date = DateTime->now;

            my $basketinfo = {
                basketname => $basketname,
                booksellerid => $self->booksellerid,
                create_items => 'ordering',
		creationdate => $date,
		authorisedby => C4::Context->userenv->{'number'},
                billingplace => C4::Context->userenv->{'branch'}
            };

            my $basket = Koha::Acquisition::Basket->new($basketinfo)->store;
            $basketno = $basket->basketno;
        }
    } else {
        $basketno = undef;
    }

    if (defined $basketno && $basketno ne '') {
        $self->{basketno} = $basketno;
        my $url = URI->new('/cgi-bin/koha/acqui/basket.pl');
        $url->query_form('basketno' => $self->{basketno});
        $self->{basket_url} = $url;
    } else {
        $self->{basketno} = undef;
    }
    my $budget_id = $cgi->param('order-budget');
    if (defined $budget_id && $budget_id ne '') {
        $self->{budget_id} = $budget_id;
    } else {
        $self->{budget_id} = undef;
    }

    for my $record (@{$self->{records}}) {
        $record->update_from_cgi($cgi);
    }

    $self->record_duplicates;
}

sub new_from_orderid {
    my ( $class, $plugin, $lang, $orderid ) = @_;

    my $self = __PACKAGE__->new( $plugin, $lang );

    $self->{order_id} = $orderid;

    $self->load;

    $self->record_duplicates;

    return $self;
}

sub validate {
    my $self = shift;

    my %ef = (
        "OrderInvoiceNumber" => 2,
        "ContinueOrderingReturnURL" => 1,
        "CustomerNumber" => 2,
        "Items" => 2,
        "OrderAPIVersion" => 1,
        "OrderNote" => 1,
        "OrderNumber" => 2,
        "Vendor" => 2,
        "WhenOrderedTimestamp" => 1
    );

    for my $field (keys %{$self->{data}}) {
        if (defined $ef{$field} && $ef{$field} > 0) {
            $ef{$field} = 0;
        } else {
            if (!defined $ef{$field}) {
                $self->_warn("Unexpected field in order data: '$field'");
            }
        }
    }

    for my $field (keys %ef) {
        if ($ef{$field} == 2) {
            $self->_err("Required field '" . $field . "' is missing.");
        } elsif ($ef{$field} == 1) {
            $self->_warn("Optional field '" . $field . "' is missing.");
        }
    }

    $self->{when_ordered} = $self->parse_datetime($self->data('WhenOrderedTimestamp'), 'WhenOrderedTimestamp');

    if (defined $self->{when_ordered}) {
        $self->{when_ordered_str} = output_pref($self->{when_ordered});
    }

    $self->{order_number} = $self->data('OrderNumber');
    $self->{order_note} = $self->data('OrderNote');
    $self->{customer_number} = $self->data('CustomerNumber');
    $self->{vendor} = $self->data('Vendor');
    $self->{invoice_number} = $self->data('OrderInvoiceNumber');
    $self->{api_version} = $self->data('OrderAPIVersion');
    $self->{continue_url} = $self->data('ContinueOrderingReturnURL');

    $self->load_order_id;

    return $self->valid;
}

sub validate_items {
    my $self = shift;

    if (!is_arrayref($self->{data}->{Items})) {
        $self->_err('Items is not an array ref.');
    }

    $self->{records} = [];

    for my $item (@{$self->{data}->{Items}}) {
        $self->validate_item($item);
    }
}

sub validate_item {
    my ($self, $item_data) = @_;

    my $record = Koha::Plugin::VendorAcquisition::OrderRecord->new_from_json($self->{plugin}, $self->{lang}, $self, $item_data);

    push @{$self->{records}}, $record;
}

sub record_duplicates {
    my $self = shift;

    my %records = ();

    for my $record (@{$self->{records}}) {
        my $id = $record->record_name;

        next unless defined $id;

        if (defined $records{$id}) {
            $record->set_duplicate($records{$id});
        } else {
            $records{$id} = $record;
        }
    }

}

sub table_naming {
    my $self = shift;

    return $self->{plugin}->get_qualified_table_name($_[0]);
}

sub load_order_id {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    my $ordertable = $self->table_naming('order');

    my $sql = "SELECT order_id FROM `$ordertable` WHERE vendor = ? AND order_number = ? AND customer_number = ?";

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute($self->{vendor}, $self->{order_number}, $self->{customer_number});

    if (!$rv) {
        $self->_err("Failed to load order_id: " . $dbh->errstr);
        return;
    }

    my $row = $sth->fetchrow_hashref;
    if ($row) {
        $self->{order_id} = $row->{order_id};
    }
}

sub delete_records {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    my $recordtable = $self->table_naming('record');

    my $sql = "DELETE FROM `$recordtable` WHERE order_id = ? ";

    my @binds = ($self->{order_id});

    for my $record (@{$self->{records}}) {
        $sql .= " AND record_id != ?";
        push @binds, $record->{record_id};
    }

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute(@binds);

    if (!$rv) {
        $self->_err("Failed to delete records: " . $dbh->errstr);
    }
}

sub store {
    my $self = shift;

    $self->start_die_on_error;

    my $dbh   = C4::Context->dbh;

    my $ordertable = $self->table_naming('order');

    my $sql;

    if (defined $self->{order_id}) {
        $sql = "UPDATE `$ordertable` ";
    } else {
        $sql = "INSERT INTO `$ordertable` ";
    }

    $sql .= <<'EOF';
SET order_number = ?,
    customer_number = ?,
    invoice_number = ?,
    api_version = ?,
    continue_url = ?,
    vendor = ?,
    when_ordered = ?,
    order_note = ?,
    budget_id = ?,
    basketno = ?
EOF

    my @binds = ($self->{order_number},
                 $self->{customer_number},
                 $self->{invoice_number},
                 $self->{api_version},
                 $self->{continue_url},
                 $self->{vendor},
                 scalar(output_pref({ str => $self->{when_ordered}, dateformat => 'iso' })),
                 $self->{order_note},
                 $self->{budget_id},
                 $self->{basketno}
        );

    if (defined $self->{order_id}) {
        $sql .= " WHERE order_id = ?";

        push @binds, $self->{order_id};
    }

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute(@binds);

    if (!$rv) {
        $self->_err("Failed to store order data: " . $dbh->errstr);
    }

    if (!defined $self->{order_id}) {
        $self->{order_id} = $dbh->last_insert_id(undef, undef, $ordertable, undef);
        my $order_json_table = $self->table_naming('order_json');
        my $sth_json = $dbh->prepare("INSERT IGNORE INTO `$order_json_table` (order_id, json) VALUES (?, ?)");
        my $rv = $sth_json->execute($self->{order_id}, $self->{json});
    }


    for my $record (@{$self->{records}}) {
        $record->store;
    }

    $self->delete_records;

    $self->stop_die_on_error;
}

sub load {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    my $ordertable = $self->table_naming('order');

    my $sql;
    my @binds;

    my $cols = 'order_id, order_number, invoice_number, customer_number, api_version, continue_url, vendor, when_ordered, order_note, budget_id, basketno';

    if (defined $self->{order_id}) {
        $sql = "SELECT $cols FROM `$ordertable` WHERE order_id = ?";
        @binds = ($self->{order_id});
    } else {
        $sql = "SELECT $cols FROM `$ordertable` WHERE vendor = ? AND order_number = ? AND customer_number = ?";
        @binds = ($self->{vendor}, $self->{order_number}, $self->{customer_number});
    }

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute(@binds);

    if (!$rv) {
        $self->_err('Failed to load order: ' . $dbh->errstr);
        return;
    }

    if (my $row = $sth->fetchrow_hashref) {
        $self->{order_id} = $row->{order_id};
        $self->{order_number} = $row->{order_number};
        $self->{invoice_number} = $row->{invoice_number};
        $self->{customer_number} = $row->{customer_number};
        $self->{api_version} = $row->{api_version};
        $self->{continue_url} = $row->{continue_url};
        $self->{vendor} = $row->{vendor};
        $self->{when_ordered} = dt_from_string($row->{when_ordered}, 'sql');
        $self->{order_note} = $row->{order_note};
        $self->{budget_id} = $row->{budget_id};
        $self->{basketno} = $row->{basketno};

        $self->load_records;
        if (defined $self->{when_ordered}) {
            $self->{when_ordered_str} = output_pref($self->{when_ordered});
        }
        $self->record_duplicates;
    } else {
        $self->{is_new} = 1;
    }
}

sub load_records {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    $self->{records} = [];

    my $recordtable = $self->table_naming('record');

    my $sql = "SELECT `" . join('`, `', Koha::Plugin::VendorAcquisition::OrderRecord->fields) .  "` FROM `$recordtable` WHERE order_id = ?";

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute($self->{order_id});

    if (!$rv) {
        $self->_err("Failed to load records: " . $dbh->errstr);
        return;
    }

    while (my $row = $sth->fetchrow_hashref) {
        my $record = Koha::Plugin::VendorAcquisition::OrderRecord->new_from_hash($self->{plugin}, $self->{lang}, $self, $row);

        push @{$self->{records}}, $record;
    }
}

sub imported {
    my $self = shift;

    for my $record (@{$self->{records}}) {
        if (defined $record->{ordernumber}) {
            return 1;
        }
    }
    return 0;
}

sub process {
    my $self = shift;
    my $lang = shift;
    my $plugin = shift;

    my $plugin_dir = $plugin->bundle_path;

    my $dbh   = C4::Context->dbh;

    my @lang_split = split /_|-/, $lang;

    if ($self->imported) {
        $self->_err("Already imported.");
        return 0;
    }

    $self->start_die_on_error;

    my $booksellerid = $self->booksellerid;

    if (!defined $booksellerid) {
        $self->_err("No booksellerid in order!.");
    }

    for my $record (@{$self->{records}}) {
        $record->process;
        if ($record->{ordernumber}) {
            next;
        } else {
            my $internalnote_template = $plugin->get_template( { file => 'order_internalnote.tt' } );
            $internalnote_template->param(
                lang_dialect => $lang,
                lang_all => $lang_split[0],
                plugin_dir => $plugin_dir,
                estimated_delivery_date => output_pref({ dt => $record->{estimated_delivery_date},
                                                         dateonly => 1}),
                note => $record->{note}
                );

            my $orderinfo = {
                biblionumber => $record->{biblionumber},
                booksellerid => $booksellerid,
                basketno => $self->{basketno},
                budget_id => $self->{budget_id},
		created_by => C4::Context->userenv->{'number'},
                currency => $record->{currency},
                quantity => $record->{quantity},
                replacementprice => $record->{price_inc_vat},
                listprice => $record->{price},
                ecost => $record->{price_inc_vat},
                ecost_tax_excluded => $record->{price},
                ecost_tax_included => $record->{price_inc_vat},
                unitprice_tax_excluded => $record->{price},
                unitprice_tax_included => $record->{price_inc_vat},
                rrp_tax_included => $record->{rrp_price},
                tax_rate_bak => $record->{vat},
                order_internalnote => scalar($internalnote_template->output),
                order_vendornote => $self->{order_note},
                purchaseordernumber => $self->{order_number}
            };

            my $order = Koha::Acquisition::Order->new($orderinfo)->store;

            $record->{ordernumber} = $order->ordernumber;

            for my $item (@{$record->{items}}) {
                $order->add_item( $item->{itemnumber} );
            }
        }
    }

    $self->store;

    $self->stop_die_on_error;

    return 1;
}

sub booksellerid {
    my $self = shift;

    return $self->{booksellerid} if (defined $self->{booksellerid});

    my $dbh   = C4::Context->dbh;

    my $vmtable = $self->table_naming('vendormapping');

    my $sql = "SELECT booksellerid FROM `$vmtable` WHERE vendor = ?";

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute($self->{vendor});

    if (!$rv) {
        $self->_err("Failed to map vendor identity: " . $dbh->errstr);
        return undef;
    }

    my @row = $sth->fetchrow_array;

    if (scalar(@row) < 1) {
        $self->_err("No vendor mapping for vendor '" . $self->{vendor} . "'");
        return undef;
    }

    if (scalar(@row) > 1) {
        $self->_warn("Multiple (" . scalar(@row) . ") vendor mappings for vendor '" . $self->{vendor} . "'");
    }

    $self->{booksellerid} = $row[0];

    return $row[0];
}

sub valid {
    my $self = shift;

    return scalar($self->errors) == 0;
}

sub parse_datetime {
    my ($self, $text, $fieldname) = @_;

    my $datetime;

    return undef if !defined $text || $text =~ /^\s*$/;

    eval {
        $datetime = $self->{date_format}->parse_datetime($text);
    };

    if ($@) {
        $self->_err("Failed to parse datetime of field '$fieldname': " . $@);
    }

    return $datetime;
}

sub default_values {
    my $self = shift;

    if (defined $self->{default_values}) {
        return $self->{default_values};
    }

    my $dbh   = C4::Context->dbh;

    my $dvtable = $self->table_naming('default_values');

    my $sql = "SELECT customer_number, notforloan, homebranch, holdingbranch, itemtype, ccode, location, budget_id FROM `$dvtable` WHERE customer_number IN (?, '*')";

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute($self->{customer_number});

    if (!$rv) {
        $self->_err("Failed to query default values: " . $dbh->errstr);
        return;
    }

    my $defrule;
    my $customerrule;

    while (my $row = $sth->fetchrow_hashref) {
        if ($row->{customer_number} eq '*') {
            $defrule = $row;
        } else {
            $customerrule = $row;
        }
    }

    my $rule;

    if (defined $customerrule) {
        $rule = $customerrule;
    } elsif (defined $defrule) {
        $rule = $defrule;
    }

    $self->{default_values} = $rule;

    return $rule;
}


sub format_datetime {
    my $self = shift;
    my $datetime = shift;

    return $self->{date_format}->format_datetime($datetime);
}

sub start_die_on_error {
    my ($self, $die_on_error) = @_;

    $self->{die_on_error}++;
}

sub stop_die_on_error {
    my $self = shift;

    $self->{die_on_error}--;
}

sub die_on_error {
    my $self = shift;

    return $self->{die_on_error} > 0;
}

sub _err {
    my ($self, $msg, $nopush) = @_;

    my $logger = Koha::Logger->get;

    unless ($nopush) {
        push @{$self->{errors}}, $msg;
    }

    if ($self->die_on_error) {
        die $msg;
    }
    
    $logger->error("$msg");
}

sub _warn {
    my ($self, $msg, $nopush) = @_;

    my $logger = Koha::Logger->get;

    unless ($nopush) {
        push @{$self->{warnings}}, $msg;
    }

    $logger->warn("$msg");
}

sub errors {
    my $self = shift;

    return @{$self->{errors}};
}

sub all_errors {
    my $self = shift;

    my @errors = @{$self->{errors}};

    for my $record (@{$self->{records}}) {
        push @errors, $record->all_errors;
    }

    return @errors;
}

sub warnings {
    my $self = shift;

    return @{$self->{warnings}};
}

sub data {
    my ($self, $field) = @_;

    return $self->{data}->{$field};
}

sub cleanup {
    my $self = shift;

    for my $record (@{$self->{records}}) {
        $record->cleanup;
    }    
}


1;
