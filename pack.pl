#!/usr/bin/perl

# Copyright 2026 Magnus Enger, Libriotech <magnus@libriotech.no>
#
# This file is part of koha-plugin-disdk-search.
#
# koha-plugin-disdk-search is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# koha-plugin-disdk-search is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with koha-plugin-disdk-search; if not, see <http://www.gnu.org/licenses>.

=pod

=head1 pack.pl

Package up the relevant parts as a .kpz Koha plugin file.

=head1 USAGE

  perl pack.pl

=head1 PREREQUISITES

=head2 zip

  sudo apt-get install zip

=cut

use Modern::Perl;
use lib '.';

my $filename = "/tmp/koha-plugin-vendor-acquisition-imcode-3.1.kpz";
unlink $filename if -f $filename;

chdir('src') or die "$!";
say `zip -r $filename Koha/`;

if ( -f $filename ) {
    say "$filename created";
} else {
    say "Oooops, something went wrong!";
}
