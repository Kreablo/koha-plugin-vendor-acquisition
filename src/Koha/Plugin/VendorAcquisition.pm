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

package Koha::Plugin::VendorAcquisition;

use C4::Auth;
use C4::Matcher;
use JSON;
use URI;
use Koha::Logger;

use strict;

use parent qw(Koha::Plugins::Base);
use Koha::Plugin::VendorAcquisition::Order;
use Koha::Acquisition::Booksellers;
use Koha::AuthorisedValues;
use Koha::Database;

our $VERSION = "1.17";
our $API_VERSION = "1.0";

our $metadata = {
    name            => 'Vendor Acquisition Module',
    author          => 'Andreas Jonsson',
    date_authored   => '2020-01-04',
    date_updated    => "2023-02-10",
    minimum_version => 20.05,
    maximum_version => '',
    version         => $VERSION,
    description     => 'Handling of acquired orders from vendors such as Adlibris.'
};

my $debug = 1;

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);
    $self->{'class'} = $class;

    return $self;
}

sub version_cmp {
    my ($av, $bv) = @_;

    my @a = split /\./, $av;
    my @b = split /\./, $bv;

    for (my $i = 0; $i < scalar(@a) && $i < scalar(@b); $i++) {
        if ($a[$i] < $b[$i]) {
            return -1;
        }
        if ($a[$i] > $b[$i]) {
            return 1;
        }
    }

    return 0;
}

sub install {
    my ( $self, $args ) = @_;

    my $dbh   = C4::Context->dbh;

    my $success = $dbh->do("INSERT IGNORE INTO permissions (module_bit, code, description) VALUES ((SELECT bit FROM userflags WHERE flag='plugins'), 'vendor_order_receive', 'Receive order using Vendor Acquisition plugin')");

    if (!$success) {
        return 0;
    }

    my $ordertable = $self->get_qualified_table_name('order');

    $success = $dbh->do("CREATE TABLE IF NOT EXISTS `$ordertable`" . <<'EOF');
(
   order_id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
   order_number VARCHAR(32) CHARSET ASCII,
   customer_number VARCHAR(32) CHARSET ASCII,
   invoice_number VARCHAR(32) CHARSET ASCII,
   api_version VARCHAR(8),
   continue_url LONGTEXT,
   vendor VARCHAR(128),
   when_ordered TIMESTAMP,
   order_note LONGTEXT,
   basketno INT(11) DEFAULT NULL,
   budget_id INT DEFAULT NULL,
   imported TINYINT(1) DEFAULT 0,
   UNIQUE KEY (vendor, order_number, customer_number),
   INDEX (basketno),
   INDEX (budget_id),
   INDEX (vendor),
   FOREIGN KEY (basketno) REFERENCES aqbasket (basketno) ON UPDATE CASCADE ON DELETE SET NULL,
   FOREIGN KEY (budget_id) REFERENCES aqbudgets (budget_id) ON UPDATE CASCADE ON DELETE SET NULL
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
EOF

    if (!$success) {
        return 0;
    }

    my $recordtable = $self->get_qualified_table_name('record');

    $success = $dbh->do("CREATE TABLE IF NOT EXISTS `$recordtable`" . <<EOF);
(
    record_id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    order_id INT,
    author LONGTEXT,
    isbn VARCHAR(16),
    barcode VARCHAR(32),
    callnumber VARCHAR(32),
    callnumber_standard VARCHAR(32),
    estimated_delivery_date DATE,
    biblioid VARCHAR(32),
    biblioid_standard VARCHAR(32),
    note LONGTEXT,
    record LONGTEXT,
    currency_code VARCHAR (8),
    price DOUBLE,
    price_inc_vat DOUBLE,
    price_rrp DOUBLE,
    publisher LONGTEXT,
    quantity INT,
    title LONGTEXT,
    vat DOUBLE,
    year INT,
    biblionumber INT DEFAULT NULL,
    ordernumber INT DEFAULT NULL,
    merge_biblionumber INT DEFAULT NULL,
    INDEX (order_id),
    INDEX (isbn),
    INDEX (barcode),
    INDEX (biblionumber),
    INDEX (merge_biblionumber),
    INDEX (biblioid_standard, biblioid),
    INDEX (ordernumber),
    FOREIGN KEY (order_id) REFERENCES `$ordertable` (order_id) ON UPDATE CASCADE ON DELETE CASCADE,
    FOREIGN KEY (biblionumber) REFERENCES biblio (biblionumber) ON UPDATE CASCADE ON DELETE SET NULL,
    FOREIGN KEY (merge_biblionumber) REFERENCES biblio (biblionumber) ON UPDATE CASCADE ON DELETE SET NULL,
    FOREIGN KEY (ordernumber) REFERENCES aqorders (ordernumber) ON UPDATE CASCADE ON DELETE SET NULL
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
EOF

    if (!$success) {
        return 0;
    }

    my $itemtable = $self->get_qualified_table_name('item');

    $success = $dbh->do("CREATE TABLE IF NOT EXISTS `$itemtable` " . <<EOF);
(
    item_id  INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    record_id INT,
    homebranch VARCHAR(10) DEFAULT NULL COLLATE utf8mb4_unicode_ci,
    holdingbranch VARCHAR(10) DEFAULT NULL COLLATE utf8mb4_unicode_ci,
    itemtype VARCHAR(10) DEFAULT NULL COLLATE utf8mb4_unicode_ci,
    location VARCHAR(80) DEFAULT NULL,
    itemcallnumber VARCHAR(255) DEFAULT NULL,
    ccode VARCHAR(80) DEFAULT NULL,
    notforloan TINYINT(1) NOT NULL DEFAULT '0',
    price DECIMAL(8, 2) DEFAULT NULL,
    itemnumber INT DEFAULT NULL,
    barcode varchar(20) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    INDEX (record_id),
    INDEX (homebranch),
    INDEX (holdingbranch),
    INDEX (itemnumber),
    INDEX (itemtype),
    INDEX (barcode),
    FOREIGN KEY (record_id) REFERENCES `$recordtable` (record_id) ON UPDATE CASCADE ON DELETE CASCADE,
    FOREIGN KEY (homebranch) REFERENCES branches (branchcode) ON UPDATE CASCADE ON DELETE SET NULL,
    FOREIGN KEY (holdingbranch) REFERENCES branches (branchcode) ON UPDATE CASCADE ON DELETE SET NULL,
    FOREIGN KEY (itemnumber) REFERENCES items (itemnumber) ON UPDATE CASCADE ON DELETE SET NULL,
    FOREIGN KEY (itemtype) REFERENCES itemtypes (itemtype) ON UPDATE CASCADE ON DELETE SET NULL
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
EOF

    if (!$success) {
        return 0;
    }

    my $vendormapping = $self->get_qualified_table_name('vendormapping');

    $success = $dbh->do("CREATE TABLE IF NOT EXISTS `$vendormapping`" . <<'EOF');
(
   vendor VARCHAR(128) PRIMARY KEY NOT NULL,
   booksellerid INT,
   INDEX (booksellerid),
   FOREIGN KEY (booksellerid) REFERENCES aqbooksellers (id) ON UPDATE CASCADE ON DELETE CASCADE
)
EOF

    if (!$success) {
        return 0;
    }

    my $dvtable = $self->get_qualified_table_name('default_values');
    $success = $dbh->do("CREATE TABLE IF NOT EXISTS `$dvtable`" . <<'EOF');
(
   customer_number VARCHAR(32) PRIMARY KEY NOT NULL,
   notforloan TINYINT(1) DEFAULT 0,
   homebranch VARCHAR(10) DEFAULT NULL COLLATE utf8mb4_unicode_ci,
   holdingbranch VARCHAR(10) DEFAULT NULL COLLATE utf8mb4_unicode_ci,
   location VARCHAR(80) DEFAULT NULL,
   itemtype VARCHAR(10) DEFAULT NULL COLLATE utf8mb4_unicode_ci,
   ccode VARCHAR(80) DEFAULT NULL,
   budget_id INT DEFAULT NULL,
   INDEX (homebranch),
   INDEX (holdingbranch),
   INDEX (itemtype),
   FOREIGN KEY (homebranch) REFERENCES branches (branchcode) ON UPDATE CASCADE ON DELETE SET NULL,
   FOREIGN KEY (holdingbranch) REFERENCES branches (branchcode) ON UPDATE CASCADE ON DELETE SET NULL,
   FOREIGN KEY (itemtype) REFERENCES itemtypes (itemtype) ON UPDATE CASCADE ON DELETE SET NULL,
   FOREIGN KEY (budget_id) REFERENCES aqbudgets (budget_id) ON UPDATE CASCADE ON DELETE SET NULL
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
EOF

    my $order_json_table = $self->get_qualified_table_name('order_json');
    $success = $dbh->do("CREATE TABLE IF NOT EXISTS `$order_json_table`" . <<EOF);
(
   order_id INT PRIMARY KEY NOT NULL,
   json LONGTEXT,
   FOREIGN KEY (order_id) REFERENCES `$ordertable` (order_id) ON UPDATE CASCADE ON DELETE CASCADE
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
EOF

    unless ($self->retrieve_data('token')) {
        use Bytes::Random::Secure qw(random_bytes_base64);

        $self->store_data({'token' => random_bytes_base64(16, '')});
    }

    return $success;
}

sub intranet_js {
    # We must inject the label text for the custom permission
    # vendor_order_receive using a javascript, as the default is an
    # empty label in the template permissions.inc.
    return <<'EOF';
<script>
(function () {
    var load = function load () {
        if (window.jQuery) {
            window.jQuery(document).ready(function () {
                init(window.jQuery);
            });
        } else {
            setTimeout(load, 50);
        }
    };
    load();
    var init = function init ($) {
        $('#plugins_vendor_order_receive ~ label').html('<span class="sub_permission vendor_order_receive_subpermission">Receive orders with vendor acquisition plugin <span class="permissioncode">(vendor_order_receive)</span></span>');
    }
})();
</script>
EOF
}

sub uninstall {
    my ( $self, $args ) = @_;

    my $dbh = C4::Context->dbh;

    my $success = $dbh->do("DELETE FROM permissions WHERE code='vendor_order_receive' AND NOT EXISTS (SELECT * FROM user_permissions WHERE code='vendor_order_receive')");

    my $actiontable = $self->get_qualified_table_name('action');
    $dbh->do("DROP TABLE IF EXISTS `$actiontable`");

    my $itemtable = $self->get_qualified_table_name('item');
    $dbh->do("DROP TABLE IF EXISTS `$itemtable`");

    my $recordtable = $self->get_qualified_table_name('record');
    $dbh->do("DROP TABLE IF EXISTS `$recordtable`");

    my $ordertable = $self->get_qualified_table_name('order');
    $dbh->do("DROP TABLE IF EXISTS `$ordertable`");

    my $vmtable = $self->get_qualified_table_name('vendormapping');
    $dbh->do("DROP TABLE IF EXISTS `$vmtable`");

    my $dvtable = $self->get_qualified_table_name('default_values');
    $dbh->do("DROP TABLE IF EXISTS `$dvtable`");

    my $order_json = $self->get_qualified_table_name('order_json');
    $dbh->do("DROP TABLE IF EXISTS `$order_json`");

    return $success;
}

sub upgrade {
    my ( $self, $args ) = @_;

    my $success = 1;

    my $dbh = C4::Context->dbh;
    my $itemtable = $self->get_qualified_table_name('item');

    my $database_version = $self->retrieve_data('__INSTALLED_VERSION__');

    if (version_cmp($database_version, '1.2') < 0) {
        $dbh->do("ALTER IGNORE TABLE `$itemtable` ADD COLUMN barcode varchar(20) COLLATE utf8mb4_unicode_ci DEFAULT NULL AFTER itemnumber");
    }

    if (version_cmp($database_version, '1.5') < 0) {
        my $order_json_table = $self->get_qualified_table_name('order_json');
        my $ordertable = $self->get_qualified_table_name('order');
        $success = $dbh->do("CREATE TABLE IF NOT EXISTS `$order_json_table`" . <<"EOF");
(
   order_id INT PRIMARY KEY NOT NULL,
   json LONGTEXT,
   FOREIGN KEY (order_id) REFERENCES `$ordertable` (order_id) ON UPDATE CASCADE ON DELETE CASCADE
) DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
EOF

    }

    if (version_cmp($database_version, '1.9') < 0) {
        my $dvtable = $self->get_qualified_table_name('default_values');
        $dbh->do("ALTER IGNORE TABLE `$dvtable` ADD COLUMN budget_id INT DEFAULT NULL AFTER ccode");
        $dbh->do("ALTER IGNORE TABLE `$dvtable` ADD FOREIGN KEY (budget_id) REFERENCES aqbudgets(budget_id) ON UPDATE CASCADE ON DELETE SET NULL");
    }

    if (version_cmp($database_version, '1.15') < 0) {
        my $otable = $self->get_qualified_table_name('order');
        $dbh->do("ALTER IGNORE TABLE `$otable` ADD COLUMN basketname varchar(50) COLLATE utf8mb4_unicode_ci DEFAULT NULL AFTER basketno");
    }

    return $success;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $save_success = 0;

    my @errors = ();

    my $vmtable = $self->get_qualified_table_name('vendormapping');
    my $dvtable = $self->get_qualified_table_name('default_values');

    my $methods = Koha::Plugins::Methods->search(
        {
            plugin_class => $self->{'class'}
        });

    while (my $method = $methods->next) {

        # The plugin manager by default exposes every method it finds
        # in this package and in the parent package.  We clean this up
        # when we configure the plugin.

        if (! grep {$_ eq $method->plugin_method} ('configure', 'install', 'uninstall', 'upgrade', 'enable', 'disable', 'vendor_order_receive', 'intranet_js')) {
            $method->delete;
        }
    }

    my $lang = C4::Languages::getlanguage($cgi);
    my @lang_split = split /_|-/, $lang;

    my $receive_url =
      URI->new( C4::Context->preference('staffClientBaseURL')
                . '/cgi-bin/koha/plugins/run.pl');

    my $token = $self->retrieve_data('token');

    $receive_url->query_form('class' => $self->{'class'}, method => 'vendor_order_receive', token => $token);

    my $record_match_rule = $cgi->param('record_match_rule');

    if (!defined $record_match_rule) {
        $record_match_rule = $self->retrieve_data('record_match_rule');
    }

    my $booksellers = Koha::Acquisition::Booksellers->search(undef, { order_by => { -asc => ['name'] }});

    my @matchers = C4::Matcher::GetMatcherList();
    @matchers = sort { $a->{code} cmp $b->{code} } @matchers;

    my $matcher_error = 0;

    if ($record_match_rule ne '') {
        my $matcher_id = C4::Matcher::GetMatcherId($record_match_rule);

        $matcher_error = !(defined $matcher_id && defined C4::Matcher->fetch( $matcher_id )) && !defined C4::Matcher->fetch($record_match_rule);
    }

    my $dbh   = C4::Context->dbh;

    if ( $cgi->request_method eq 'POST' && $cgi->param('save') && $cgi->param('token') eq $token) {

        my @vendor_mapping_ids = $cgi->multi_param('vendor-id');
        my @vendor_mapping_koha_ids = $cgi->multi_param('koha-vendor-id');


        my %vendor_mappings = ();
        my @vendor_mappings = ();

        for (my $i = 0; $i < scalar(@vendor_mapping_ids); $i++) {
            last if $i >= scalar(@vendor_mapping_koha_ids);
            $vendor_mappings{$vendor_mapping_ids[$i]} = $vendor_mapping_koha_ids[$i];
        }

        while (my ($id, $kid) = each(%vendor_mappings)) {
            push @vendor_mappings, {
                vendor_id => $id,
                koha_vendor_id => $kid
            };
        }

        my $rv = $dbh->do("DELETE FROM `$vmtable`");
        if (!$rv) {
            push @errors, "Failed to clean vendor mappings table";
            $dbh->rollback;
            goto DISPLAY;
        }

        my $rv = $dbh->do("DELETE FROM `$dvtable`");
        if (!$rv) {
            push @errors, "Failed to clean default values table";
            $dbh->rollback;
            goto DISPLAY;
        }

        if (scalar(@vendor_mappings) > 0) {
            my $vmsql = "INSERT IGNORE INTO `$vmtable` (vendor, booksellerid) VALUES ";
            my $first = 1;
            my @binds = ();
            for my $vm (@vendor_mappings) {
                if ($first) {
                    $first = 0;
                } else {
                    $vmsql .= ", ";
                }
                $vmsql .= "(?, ?)";
                push @binds, $vm->{vendor_id};
                push @binds, $vm->{koha_vendor_id};
            }

            my $sth = $dbh->prepare($vmsql);

            $rv = $sth->execute(@binds);

            if (!$rv) {
                push @errors, "Failed to save vendor mappings.";
                $dbh->rollback;
                goto DISPLAY;
            }
        }

        my @dv_customer_id = $cgi->multi_param('customer-id');
        my @dv_homebranch = $cgi->multi_param('default-homebranch');
        my @dv_holdingbranch = $cgi->multi_param('default-holdingbranch');
        my @dv_location = $cgi->multi_param('default-location');
        my @dv_notforloan = $cgi->multi_param('default-notforloan');
        my @dv_ccode = $cgi->multi_param('default-ccode');
        my @dv_itemtype = $cgi->multi_param('default-itemtype');
        my @dv_budget_id = $cgi->multi_param('default-budget_id');

        my %default_values = ();
        my @default_values = ();

        for (my $i = 0; $i < scalar(@dv_customer_id); $i++) {
            last if $i >= scalar(@dv_homebranch) || $i >= scalar(@dv_holdingbranch) || $i >= scalar(@dv_location) || $i > scalar(@dv_notforloan) || $i > scalar(@dv_itemtype) || $i > scalar(@dv_ccode) || $i > scalar(@dv_budget_id) ;
            $default_values{$dv_customer_id[$i]} = {
                customer_id => $dv_customer_id[$i],
                homebranch => $dv_homebranch[$i],
                holdingbranch => $dv_holdingbranch[$i],
                location => $dv_location[$i],
                notforloan => $dv_notforloan[$i],
                itemtype => $dv_itemtype[$i],
                ccode => $dv_ccode[$i],
                budget_id => $dv_budget_id[$i]
            };
        }

        while (my ($id, $dv) = each(%default_values)) {
            push @default_values, $dv;
        }

        if (scalar(@default_values) > 0) {

            my $dvsql = "INSERT IGNORE INTO `$dvtable` (customer_number, notforloan, homebranch, holdingbranch, location, itemtype, ccode, budget_id) VALUES ";
            my $first = 1;
            my @binds = ();

            my $p = sub {
                push @binds, (defined $_[0] && $_[0] ne '' ? $_[0] : undef);
            };

            for my $dv (@default_values) {
                if ($first) {
                    $first = 0;
                } else {
                    $dvsql .= ", ";
                }
                $dvsql .= "(?, ?, ?, ?, ?, ?, ?, ?)";
                $p->($dv->{customer_id});
                $p->($dv->{notforloan});
                $p->($dv->{homebranch});
                $p->($dv->{holdingbranch});
                $p->($dv->{location});
                $p->($dv->{itemtype});
                $p->($dv->{ccode});
                $p->($dv->{budget_id});
            }

            my $sth = $dbh->prepare($dvsql);

            $rv = $sth->execute(@binds);

            if (!$rv) {
                push @errors, "Failed to save vendor mappings.";
                $dbh->rollback;
                goto DISPLAY;
            }
        }

        $self->store_data({
            demomode => scalar($cgi->param('demomode')),
            record_match_rule => $record_match_rule,
        });

        $save_success = 1;
    }


  DISPLAY:

    my $vms = $dbh->selectall_arrayref("SELECT vendor, booksellerid FROM `$vmtable`");
    my @vendor_mappings = ();

    for my $vm (@$vms) {
        push @vendor_mappings, {
            vendor_id => $vm->[0],
            koha_vendor_id => $vm->[1]
        };
    }

    my $dvs = $dbh->selectall_arrayref("SELECT customer_number, notforloan, homebranch, holdingbranch, location, ccode, itemtype, budget_id FROM `$dvtable`");
    my @default_values = ();

    for my $dv (@$dvs) {
        push @default_values, {
            customer_id => $dv->[0],
            notforloan => $dv->[1],
            homebranch => $dv->[2],
            holdingbranch => $dv->[3],
            location => $dv->[4],
            ccode => $dv->[5],
            itemtype => $dv->[6],
            budget_id => $dv->[7]
        };
    }

    my $budgets = budget_list();

    my $template = $self->get_template( { file => 'configure.tt' } );
    $template->param(
        lang_dialect => $lang,
        lang_all => $lang_split[0],
        plugin_dir => $self->bundle_path,
        receive_url => $receive_url,
        config_js => $self->mbf_path('config.js'),
        token => $token,
        record_match_error => $matcher_error,
        record_match_rule => $record_match_rule,
        demomode => $self->retrieve_data('demomode'),
        booksellers => $booksellers->unblessed,
        budgets => $budgets,
        matchers => \@matchers,
        vendor_mappings => \@vendor_mappings,
        errors => \@errors,
        save_success => $save_success,
        notforloanav => Koha::AuthorisedValues->search({ category => 'NOT_LOAN' }, { order_by => { -asc => ['lib'] } })->unblessed,
        locav => Koha::AuthorisedValues->search({ category => 'LOC' }, { order_by => { -asc => ['lib'] }})->unblessed,
        ccodeav => Koha::AuthorisedValues->search({ category => 'CCODE' }, { order_by => { -asc => ['lib'] }})->unblessed,
        branches => Koha::Libraries->search(undef, { order_by => { -asc => ['branchname'] }})->unblessed,
        itemtypes => Koha::ItemTypes->search(undef, { order_by => { -asc => ['description'] }})->unblessed,
        default_values => \@default_values,
        can_configure => C4::Auth::haspermission(C4::Context->userenv->{'id'}, {'plugins' => 'configure'})
        );

    $self->output_html( $template->output() );
}

my $budget_list;

sub budget_list {
    my $dbh   = C4::Context->dbh;

    if (defined $budget_list) {

        return $budget_list;
    }

    my $query = <<'EOF';
SELECT budget_id, budget_name FROM aqbudgets JOIN aqbudgetperiods USING (budget_period_id) WHERE budget_period_active ORDER BY budget_name ASC;
EOF

    my $sth = $dbh->prepare($query);

    $sth->execute();

    $budget_list = [];

    while (my $budget = $sth->fetchrow_hashref) {
        push @$budget_list, $budget;
    }

    return $budget_list;
}

sub vendor_order_receive {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $lang = C4::Languages::getlanguage($cgi);
    my @lang_split = split /_|-/, $lang;

    my $receive_url =
      URI->new( C4::Context->preference('staffClientBaseURL')
                . '/cgi-bin/koha/plugins/run.pl');
    my $configure_url =
      URI->new( C4::Context->preference('staffClientBaseURL')
                . '/cgi-bin/koha/plugins/run.pl');

    my $token = $self->retrieve_data('token');
    my $token_success = ($cgi->param('token') eq $token || $cgi->url_param('token') eq $token);

    $receive_url->query_form('class' => $self->{'class'}, method => 'vendor_order_receive', token => $token);
    $configure_url->query_form('class' => $self->{'class'}, method => 'configure');


    if ($cgi->request_method eq 'POST') {

        my $order = {};

        my $save = 0;
        my $already_processed = 0;

        if ($token_success) {

            my $dbh   = C4::Context->dbh;
            $dbh->{RaiseError} = 1;

            my $schema = Koha::Database->schema;

            eval {
                $schema->txn_do(sub {
                    if ($cgi->param('save') eq 'save') {
                        $order = Koha::Plugin::VendorAcquisition::Order->new_from_orderid($self, $lang, scalar($cgi->param('order_id')));
                        $order->update_from_cgi($cgi);
                        if ($order->valid) {
                            $order->store;
                        }
                        $save = 1;
                    } elsif ($cgi->param('save') eq 'process') {
                        $order = Koha::Plugin::VendorAcquisition::Order->new_from_orderid($self, $lang, scalar($cgi->param('order_id')));
                        $order->update_from_cgi($cgi);
                        $order->start_die_on_error;
                        if ($order->valid) {
                            $order->store;
                        } else {
                            die "Order is invalid!";
                        }
                        $already_processed = $order->imported;
                        if (!$already_processed) {
                            $order->process($lang, $self);
                            if ($order->valid) {
                                $order->store;
                            } else {
                                die "Order is invalid!";
                            }
                        }
                        $order->stop_die_on_error;
                        $save = 1;
                    } else {
                        my $json = $cgi->param('order');
                        $order = Koha::Plugin::VendorAcquisition::Order->new_from_json($self, $lang, $json);
                        if ($order->valid) {
                            $order->store;
                            $order->load;
                        }
                    }
                });
            };

            if ($@) {
                $order->{die_on_error} = 0;

                my $msg = "Failed to commit order data: " . $@;
                my $logger = Koha::Logger->get;

                $logger->error($msg);
                push @{$order->{errors}}, $msg;
            }

        } else {
            my $logger = Koha::Logger->get;

            $logger->warn('Invalid security token.  cgi->param: "' . $cgi->param('token') . '" url_param: "' . $cgi->url_param('token') . '" token: "' . $token . '"');
            $order->{errors} = ('Invalid security token.');
        }

        if ($token_success && $order->valid) {
            my ($template, $loggedinuser, $cookie) = C4::Auth::get_template_and_user({
                template_name   => $self->mbf_path('receive.tt'),
                query => $cgi,
                type => "intranet",
                debug => $debug,
                authnotrequired => 1,
                flagsrequired   => {}
            });

            if ($cgi->param('save') eq 'process' && $save) {
                print $cgi->redirect($order->{basket_url});
            } else {

                my $budgets = budget_list();

                $template->param(
                    lang_dialect => $lang,
                    lang_all => $lang_split[0],
                    plugin_dir => $self->bundle_path,
                    receive_url => $receive_url,
                    receive_js => $self->mbf_path('receive.js'),
                    notforloanav => Koha::AuthorisedValues->search({ category => 'NOT_LOAN' }, { order_by => { -asc => ['lib'] } })->unblessed,
                    locav =>  Koha::AuthorisedValues->search({ category => 'LOC' }, { order_by => { -asc => ['lib'] } })->unblessed,
                    ccodeav => Koha::AuthorisedValues->search({ category => 'CCODE' }, { order_by => { -asc => ['lib'] } })->unblessed,
                    branches => Koha::Libraries->search(undef, { order_by => { -asc => ['branchname'] } })->unblessed,
                    budgets => $budgets,
                    baskets => Koha::Acquisition::Baskets->search(undef, { order_by => { -asc => ['basketname'] } })->unblessed,
                    itemtypes => Koha::ItemTypes->search(undef, { order_by => { -asc => ['description'] } })->unblessed,
                    configure_url => $configure_url,
                    CLASS       => $self->{'class'},
                    METHOD      => scalar $self->{'cgi'}->param('method'),
                    PLUGIN_PATH => $self->get_plugin_http_path(),
                    PLUGIN_DIR  => $self->bundle_path,
                    LANG        => C4::Languages::getlanguage($self->{'cgi'}),
                    order       => $order,
                    save        => $save,
                    already_processed => $already_processed,
                    can_configure => C4::Auth::haspermission(C4::Context->userenv->{'id'}, {'plugins' => 'configure'}),
                    token       => $self->retrieve_data('token')
                    );

                $self->output_html( $template->output() );
            }
        } else {
            my $template = $self->get_template({file => 'order_failed.tt'});

            $template->param(
                lang_dialect => $lang,
                lang_all => $lang_split[0],
                plugin_dir => $self->bundle_path,
                receive_url => $receive_url,
                configure_url => $configure_url,
                order => $order,
                token       => $self->retrieve_data('token'),
                token_success => $token_success,
                request_method => $cgi->request_method
                );

            $self->output_html( $template->output() );
        }

    } elsif ($self->retrieve_data('demomode')) {
        my ($template, $loggedinuser, $cookie) = C4::Auth::get_template_and_user({
            template_name   => $self->mbf_path('receive-test.tt'),
            query => $cgi,
            type => "intranet",
            debug => $debug,
            authnotrequired => 1,
            flagsrequired   => {}
         });

        $template->param(
            lang_dialect => $lang,
            lang_all => $lang_split[0],
            plugin_dir => $self->bundle_path,
            receive_url => $receive_url,
            CLASS       => $self->{'class'},
            METHOD      => scalar $self->{'cgi'}->param('method'),
            PLUGIN_PATH => $self->get_plugin_http_path(),
            PLUGIN_DIR  => $self->bundle_path,
            LANG        => C4::Languages::getlanguage($self->{'cgi'}),
            token       => $self->retrieve_data('token')
            );

        $self->output_html( $template->output() );

    } else {
      my ($template, $loggedinuser, $cookie) = C4::Auth::get_template_and_user({
            template_name   => $self->mbf_path('order_failed.tt'),
            query => $cgi,
            type => "intranet",
            debug => $debug,
            authnotrequired => 1,
            flagsrequired   => {}
         });

      $template->param(
          lang_dialect => $lang,
          lang_all => $lang_split[0],
          plugin_dir => $self->bundle_path,
          receive_url => $receive_url,
          CLASS       => $self->{'class'},
          METHOD      => scalar $self->{'cgi'}->param('method'),
          PLUGIN_PATH => $self->get_plugin_http_path(),
          PLUGIN_DIR  => $self->bundle_path,
          LANG        => C4::Languages::getlanguage($self->{'cgi'}),
          token       => $self->retrieve_data('token'),
          token_success => $token_success,
          request_method => $cgi->request_method
          );

        $self->output_html( $template->output() );
    }
}

1;

