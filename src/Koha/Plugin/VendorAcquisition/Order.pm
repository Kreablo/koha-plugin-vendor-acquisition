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
use C4::Templates;
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


sub set_basketno {
    my $self = shift;

    my $basket;

    if (defined $self->{basketno}) {
        $basket = Koha::Acquisition::Baskets->find({ basketno => $self->{basketno}});
        if (defined $basket && defined $self->{basketname} && $basket->basketname eq $self->{basketname}) {
            return;
        }
    }

    if (defined $self->{basketname}) {
        my $baskets = Koha::Acquisition::Baskets->search({ basketname => $self->{basketname} });
        if ($baskets->count > 0) {
            $basket = $baskets->next;
        } else {
            my $date = DateTime->now;

            my $basketinfo = {
                basketname => $self->{basketname},
                booksellerid => $self->booksellerid,
                create_items => 'ordering',
                creationdate => $date,
                authorisedby => C4::Context->userenv->{'number'},
                billingplace => C4::Context->userenv->{'branch'}
            };

            $basket = Koha::Acquisition::Basket->new($basketinfo)->store;
        }
        $self->{basketno} = $basket->basketno;
        $self->{basketname} = undef;
    }

    if (defined $self->{basketno} && $self->{basketno} ne '') {
        my $url = URI->new('/cgi-bin/koha/acqui/basket.pl');
        $url->query_form('basketno' => $self->{basketno});
        $self->{basket_url} = $url;
    } else {
        $self->_err("No basket for order!");
        $self->{basketno} = undef;
    }
}

sub update_from_cgi {
    my ($self, $cgi) = @_;

    my $dbh   = C4::Context->dbh;
    my $basketType = $cgi->param('basket-type');
    $self->{basket_type} = $basketType;

    if ($basketType eq 'existing') {
        $self->{basketno} = $cgi->param('order-basket');
        $self->{basketname} = undef;
    } elsif ($basketType eq 'new-order' || $basketType eq 'new') {
        my $basketname = $basketType eq 'new-order' ? $self->{order_number} : $cgi->param('order-basketname');
        $self->{basketname} = $basketname;
    }

    my $budget_id = $cgi->param('order-budget');
    if (defined $budget_id && $budget_id ne '') {
        $self->{budget_id} = $budget_id;
    } else {
        $self->{budget_id} = undef;
    }

    for my $record (@{$self->{records}}) {
        eval {
            $record->update_from_cgi($cgi);
        };
        if ($@) {
            $self->_warn("Failed to update record: " . $@);
        }
    }

    $self->record_duplicates;

    my $order_json_id = $cgi->param('order_json_id');

    if (defined $order_json_id) {
        $self->{order_json_id} = $order_json_id;
    }

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

    eval {
        my $record = Koha::Plugin::VendorAcquisition::OrderRecord->new_from_json($self->{plugin}, $self->{lang}, $self, $item_data);

        push @{$self->{records}}, $record;
    };

    if ($@) {
        $self->_warn("Failed to parse record: " . $@);
    }
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
    basketno = ?,
    basketname = ?
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
                 $self->{basketno},
                 $self->{basketname}
        );

    if (defined $self->{order_id}) {
        $sql .= " WHERE order_id = ?";

        push @binds, $self->{order_id};
    }

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute(@binds);

    if (!defined $self->{order_id}) {
        $self->{order_id} = $dbh->last_insert_id();
    }

    if (!$rv) {
        $self->_err("Failed to store order data: " . $dbh->errstr);
    }

    for my $record (@{$self->{records}}) {
        $record->store;
    }

    $self->delete_records;

    my $order_json_id = $self->{'order_json_id'};

    if (defined $order_json_id) {
        my $order_json_table = $self->table_naming('order_json');
        my $sth_json = $dbh->prepare("UPDATE `$order_json_table` SET order_id=? WHERE order_json_id=? AND order_id IS NULL AND NOT EXISTS (SELECT * FROM `$order_json_table` WHERE order_id=?)");
        my $rv = $sth_json->execute($self->{order_id}, $order_json_id, $self->{order_id});
    }

    $self->stop_die_on_error;
}

sub load {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    my $ordertable = $self->table_naming('order');

    my $sql;
    my @binds;

    my $cols = 'order_id, order_number, invoice_number, customer_number, api_version, continue_url, vendor, when_ordered, order_note, budget_id, basketno, basketname';

    if (defined $self->{order_id} && $self->{order_id} ne '') {
        $sql = "SELECT $cols FROM `$ordertable` WHERE order_id = ?";
        @binds = ($self->{order_id});
    } else {
        $sql = "SELECT $cols FROM `$ordertable` WHERE vendor = ? AND order_number = ? AND customer_number = ?";
        @binds = ($self->{vendor}, $self->{order_number}, $self->{customer_number});
    }

    my $sth = $dbh->prepare($sql . ' FOR UPDATE');

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
        $self->{basketname} = $row->{basketname};

        if (defined $self->{basketname}) {
            my $baskets = Koha::Acquisition::Baskets->search({ basketname => $self->{basketname} });
            if ($baskets->count > 0) {
                $self->{basket_type} = 'existing';
                $self->{basketno} = $baskets->next->basketno;
            } elsif ($self->{basketname} eq $self->{order_number}) {
                $self->{basket_type} = 'new-order';
                $self->{basketname} = undef;
            } else {
                $self->{basket_type} = 'new';
            }
        }

        $self->load_records;
        if (defined $self->{when_ordered}) {
            $self->{when_ordered_str} = output_pref($self->{when_ordered});
        }
        $self->record_duplicates;
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
        for my $item (@{$record->{items}}) {
            if (defined $item->{ordernumber}) {
                return 1;
            }
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

    $self->set_basketno;

    my $booksellerid = $self->booksellerid;

    if (!defined $booksellerid) {
        $self->_err("No booksellerid in order!.");
    }

    for my $record (@{$self->{records}}) {
        $record->process;
        my $internalnote_template = C4::Templates::gettemplate( $plugin->mbf_path('order_internalnote.tt'), 'intranet', $plugin->{cgi});

        $internalnote_template->param(
            CLASS       => $plugin->{'class'},
            METHOD      => scalar $plugin->{'cgi'}->param('method'),
            PLUGIN_PATH => $plugin->get_plugin_http_path(),
            PLUGIN_DIR  => $plugin->bundle_path(),
            LANG        => C4::Languages::getlanguage($self->{'cgi'}),
            lang_dialect => $lang,
            lang_all => $lang_split[0],
            plugin_dir => $plugin_dir,
            estimated_delivery_date => output_pref({ dt => $record->{estimated_delivery_date},
                                                     dateonly => 1}),
            note => $record->{note}
            );

        my $main_price = $record->{$plugin->retrieve_data('price_including_vat') ? 'price_inc_vat' : 'price'};

        my $orderinfo = {
            biblionumber => $record->{biblionumber},
            booksellerid => $booksellerid,
            basketno => $self->{basketno},
            budget_id => $self->{budget_id},
            created_by => C4::Context->userenv->{'number'},
            currency => $record->{currency},
            quantity => $record->{quantity},
            listprice => $record->{price},
            ecost => $main_price,
            ecost_tax_excluded => $record->{price},
            ecost_tax_included => $record->{price_inc_vat},
            unitprice => $main_price,
            unitprice_tax_excluded => $record->{price},
            unitprice_tax_included => $record->{price_inc_vat},
            tax_rate_bak => $record->{vat},
            order_internalnote => scalar($internalnote_template->output),
            order_vendornote => $self->{order_note},
            purchaseordernumber => $self->{order_number}
        };

        if (C4::Context->preference("Version") >= 22.11) {
            $orderinfo->{estimated_delivery_date} = $record->{estimated_delivery_date}
        }

        if (defined($record->{rrp_price}) && $record->{rrp_price} > 0) {
            $orderinfo->{rrp} = $record->{rrp_price};
            $orderinfo->{rrp_tax_included} = $record->{rrp_price};
        }

        if ($plugin->retrieve_data('fill_out_replacementprice')) {
            $orderinfo->{replacementprice} = $record->{price_inc_vat};
        }

        my $order = Koha::Acquisition::Order->new($orderinfo)->store;

        my %order_per_budget = ($self->{budget_id} => $order);

        for my $item (@{$record->{items}}) {
            my $budget_id = $item->{budget_id} // $self->{budget_id};
            my $o = $order_per_budget{$budget_id};
            if (!defined $o) {
                $orderinfo->{budget_id} = $budget_id;
                $orderinfo->{quantity} = 1;
                $o = Koha::Acquisition::Order->new($orderinfo)->store;
                $order_per_budget{$budget_id} = $o;
            } elsif ($budget_id != $self->{budget_id}) {
                $o->quantity($o->quantity + 1);
                $o->store;
            }
            if ($budget_id != $self->{budget_id}) {
                if ($order->quantity == 1) {
                    $order->delete;
                } else {
                    $order->quantity($order->quantity - 1);
                    $order->store;
                }
            }
            $o->add_item( $item->{itemnumber} );
            $item->{ordernumber} = $o->ordernumber;
            $item->store;
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

    return scalar($self->all_errors) == 0;
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

    $logger->error($msg);
}

sub _warn {
    my ($self, $msg, $nopush) = @_;

    my $logger = Koha::Logger->get;

    unless ($nopush) {
        push @{$self->{warnings}}, $msg;
    }

    $logger->warn($msg);
}

sub errors {
    my $self = shift;

    return @{$self->{errors}};
}

sub all_errors {
    my $self = shift;

    my @errors = (@{$self->{errors}});

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
