package Koha::Plugin::VendorAcquisition::Controller;

use Modern::Perl;
use C4::Context;
use Mojo::URL;
use URI;

use Mojo::Base 'Mojolicious::Controller';

sub add_order {
    my $c = shift->openapi->valid_input or return;
    my $plugin  = Koha::Plugin::VendorAcquisition->new;
    my $in_url = URI->new($c->req->url->to_abs->to_string);
    my $in_host = $in_url->host;
    my $c_host_uri = URI->new($plugin->retrieve_data('intra_host'));
    my $c_host = URI->new($plugin->retrieve_data('intra_host'))->host;

    if (lc $in_host ne lc $c_host) {
        $c->render(
            status => 403,
            text   => "The hostname or port is invalid, expected: '$c_host', was: '$in_host'",
        );
        return;
    }

    my $in_token = $c->param('token');
    my $c_token = $plugin->retrieve_data('token');
    if ( !defined $in_token ) {
        $c->render(
            status => 400,
            text   => 'Token parameter missing on request.',
        );
        return;
    }

    if ( $in_token ne $c_token ) {
        $c->render(
            status => 403,
            text   => 'The token is an invalid.',
        );
        return;
    } else {
        my $dbh   = C4::Context->dbh;
        $dbh->{RaiseError} = 1;

        my $schema = Koha::Database->schema;
        my $json = $c->param('order');
        my $order_json_id;
        my $order_json_table = $plugin->get_qualified_table_name('order_json');

        $schema->txn_do(sub {
            $dbh->do("INSERT INTO `$order_json_table` (json) VALUES (?)", { RaiseErrors => 1 }, $json);
            $order_json_id = $dbh->last_insert_id;
        });

        if ($@) {
            $c->render(
                status => 500,
                text   => 'Could not save json code.',
            );
            return;
        }

        my $next_url =
            URI->new( $plugin->retrieve_data('intra_host')
                      . '/cgi-bin/koha/plugins/run.pl');

        $next_url->query_form(
            'class' => 'Koha::Plugin::VendorAcquisition',
            method => 'vendor_order_receive',
            token => $c_token,
            order_json_id => $order_json_id
        );

        $c->res->headers->header( 'Location' => $next_url );
        $c->rendered( 302 );
    }
}

1;
