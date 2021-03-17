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

    for my $field (qw(notforloan homebranch holdingbranch location itemnumber)) {
        my $val = $cgi->param($field . '-' . $self->{item_id});
        if (defined $val) {
            $self->{$field} = $val;
        }
    }
}

sub initiate {
    my $self = shift;

    my $dbh   = C4::Context->dbh;

    my $dvtable = $self->table_naming('default_values');

    my $sql = "SELECT customer_number, notforloan, homebranch, holdingbranch, itemtype, ccode, location FROM `$dvtable` WHERE customer_number IN (?, '*')";

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute($self->{record}->{order}->{customer_number});

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

    if (defined $rule) {
        for my $field ('customer_number', 'notforloan', 'homebranch', 'holdingbranch', 'location', 'ccode', 'itemtype') {
            if (($field eq 'homebranch' || $field eq 'holdingbranch') && (!defined $rule->{field} || $rule->{field} eq '')) {
                $self->{$field} = C4::Context->userenv->{'branch'};
            } else {
                $self->{$field} = $rule->{$field};
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

    if (defined $self->{item_id}) {
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
    price = ?
EOF
    my @binds = (
        $self->{record}->{record_id},
        $self->{notforloan},
        $self->{homebranch},
        $self->{holdingbranch},
        $self->{location},
        $self->{itemtype},
        $self->{ccode},
        $self->{itemnumber},
        $self->{barcode},
        $self->{itemcallnumber},
        $self->{price}
        );

    warn "item store record_id "  . $self->{record}->{record_id};

    if (defined $self->{item_id}) {
        $sql .= ' WHERE item_id = ?';
        push @binds, $self->{item_id};
    }

    my $sth = $dbh->prepare($sql);

    my $rv = $sth->execute(@binds);

    if (!$rv) {
        $self->_err("Failed to save item: " . $dbh->errstr);
        goto FAIL;
    }

    if (!defined $self->{item_id}) {
        $self->{item_id} = $dbh->last_insert_id(undef, undef, $itemtable, undef);
    }

    return 1;

  FAIL:
    return 0;
}

sub delete {
    my $self = shift;

    return if !defined $self->{item_id};

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

    my $item = Koha::Item->new({
        biblionumber => $self->{record}->{biblionumber},
        biblioitemnumber => $biblioitemnumber,
        homebranch => $self->{homebranch},
        holdingbranch => $self->{holdingbranch},
        notforloan => $self->{notforloan},
        location => $self->{location},
        itype => $self->{itemtype},
        ccode => $self->{ccode},
        barcode => $barcode,
        itemcallnumber => $self->{record}->{callnumber},
        price => $self->{record}->{price}
                               })->store;

    if (!defined $item) {
        $self->_err("Failed to generate koha item.");
        return 0;
    }

    $self->{itemnumber} = $item->itemnumber;

    return 1;
}

sub fields {
    return qw(item_id record_id notforloan homebranch holdingbranch location itemtype ccode itemnumber barcode);
}

sub _err {
    my ($self, $msg) = @_;

    warn "ERROR: $msg";

    push @{$self->{errors}}, $msg;
}

sub _warn {
    my ($self, $msg) = @_;

    warn "WARNING: $msg";

    push @{$self->{warnings}}, $msg;
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
