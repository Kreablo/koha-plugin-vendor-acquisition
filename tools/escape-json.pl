#!/usr/bin/perl -w

use strict;

use Encode::Locale 'decode_argv';
use Getopt::Long::Descriptive;
use JSON::XS;

decode_argv();
my ($opt, $usage) = describe_options(
    '%c %o <some-arg>',
    [ 'input=s', 'file path of input data', { required => 1 } ],
    [],
    [ 'verbose|v',  "print extra stuff"            ],
    [ 'debug',      "Enable debug output" ],
    [ 'help',       "print usage message and exit", { shortcircuit => 1 } ],
);

if ($opt->help) {
    print STDERR $usage->text;
    exit 0;
}

open INPUT, "<:utf8", $opt->input or die "Failed to open input file '" . $opt->input . "': $!";

my $input = '';

while (1) {
    my $data;

    my $n = read INPUT, $data, 4099;

    if (!defined $n) {
        die "Failed to read input file: $!";
    }

    $input .= $data;

    last if $n == 0;
}

while (my $data = <INPUT>) {
    $input .= $data;
}
        

my $data = {
    data => $input
};


my $json = new JSON::XS;

binmode STDOUT, ":raw";

print $json->utf8->encode($data);

