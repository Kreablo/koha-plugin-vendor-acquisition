package Koha::Plugin::AdlibrisAcquisition;

use C4::Auth;

use strict;

use parent qw(Koha::Plugins::Base);

our $VERSION = "00.00.01";

our $metadata = {
    name            => 'Adlibris Acquisition Module',
    author          => 'Andreas Jonsson',
    date_authored   => '2020-01-04',
    date_updated    => "2020-01-18",
    minimum_version => '20.05.01',
    maximum_version => '',
    version         => $VERSION,
    description     => 'Handling of acquired orders from Adlibris.'
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

sub install {
    my ( $self, $args ) = @_;

    my $dbh   = C4::Context->dbh;

    my $success = $dbh->do("INSERT IGNORE INTO permissions (module_bit, code, description) VALUES ((SELECT bit FROM userflags WHERE flag='plugins'), 'adlibris_order_receive', 'Receive order using Adlibris Acquisition plugin')");

    unless ($self->retrieve_data('token')) {
        use Bytes::Random::Secure qw(random_bytes_base64);

        $self->store_data('token' => random_bytes_base64(16));
    }

    return $success;
}

sub upgrade {
    my ( $self, $args ) = @_;

    my $success = 1;

    return $success;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    for my $method (Koha::Plugins::Methods->search(
                         {
                             plugin_class => $self->{'class'}
                         }
                    )) {

        # The plugin manager by default exposes every method it finds
        # in this package and in the parent package.  We clean this up
        # when we configure the plugin.

        if (! grep {$_ eq $method->plugin_method} ('configure', 'install', 'upgrade', 'adlibris_order_receive')) {
            $method->delete;
        }
    }

    my $lang = C4::Languages::getlanguage($cgi);
    my @lang_split = split /_|-/, $lang;

    my $receive_url =
      URI->new( C4::Context->preference('staffClientBaseURL')
                . '/cgi-bin/koha/plugins/run.pl');

    my $token = $self->retrieve_data('token');

    $receive_url->query_form('class' => $self->{'class'}, method => 'adlibris_order_receive', token => $token);

    unless ( $cgi->request_method eq 'POST' && $cgi->param('save') && $cgi->param('token') eq $token) {
        my $template = $self->get_template( { file => 'configure.tt' } );

        $template->param(
            lang_dialect => $lang,
            lang_all => $lang_split[0],
            plugin_dir => $self->bundle_path,
            receive_url => $receive_url,
            token => $token,
            demomode => $self->retrieve_data('demomode')
            );
        
        $self->output_html( $template->output() );
    } else {

        $self->go_home();
    }
    
}

sub adlibris_order_receive {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    my $lang = C4::Languages::getlanguage($cgi);
    my @lang_split = split /_|-/, $lang;

    my $receive_url =
      URI->new( C4::Context->preference('staffClientBaseURL')
                . '/cgi-bin/koha/plugins/run.pl');

    # Skydd mot dubbletter ordernummer/vendor/beställare
    # Prisuppgift i exemplar och inköps.

    $receive_url->query_form('class' => $self->{'class'}, method => 'adlibris_order_receive');

    if ($cgi->request_method eq 'POST') {
        
        my ($template, $loggedinuser, $cookie) = get_template_and_user({
            template_name   => $self->mbf_path('receive.tt'),
            query => $cgi,
            type => "intranet",
            flagsrequired => {
                'editcatalogue' => '*',
                'acquisition' => 'order_receive'
            },
            debug => $debug
        });

        $template->param(
            lang_dialect => $lang,
            lang_all => $lang_split[0],
            plugin_dir => $self->bundle_path,
            receive_url => $receive_url
            );

        $self->output_html( $template->output() );
    } else {
        my ($template, $loggedinuser, $cookie) = get_template_and_user({
            template_name   => $self->mbf_path('receive-test.tt'),
            query => $cgi,
            type => "intranet",
            flagsrequired => {
                'editcatalogue' => '*',
                'acquisition' => 'order_receive'
            },
            debug => $debug
         });

        $self->output_html( $template->output() );

    }

}

1;

