package DBIx::Connection::Driver;

use strict;
use warnings;

DRIVERS: {
    my %DRIVERS;

    sub new {
        my ($class, $driver) = @_;
        return $DRIVERS{$class} ||= bless { driver => $driver } => $class;
    }
}

sub ping {
    my ($self, $dbh) = @_;
    $dbh->ping;
}

sub savepoint {
    my ($self, $dbh, $name) = @_;
    die "The $self->{driver} driver does not support savepoints";
}

sub release {
    my ($self, $dbh, $name) = @_;
    die "The $self->{driver} driver does not support savepoints";
}

sub rollback_to {
    my ($self, $dbh, $name) = @_;
    die "The $self->{driver} driver does not support savepoints";
}

1;
__END__

=head1 Name

DBIx::Connection::Driver - Database-specific connection interface

=head3 C<new>

=head3 C<ping>

=head3 C<savepoint>

=head3 C<release>

=head3 C<rollback_to>

=head1 Authors

This module was written and is maintained by:

=over

=item David E. Wheeler <david@kineticode.com>

=back

It is based on code written by:

=over

=item Brandon Black <blblack@gmail.com>

=item Matt S. Trout <mst@shadowcatsystems.co.uk>

=item Alex Pavlovic <alex.pavlovic@taskforce-1.com>

=back

=head1 Copyright and License

Copyright (c) 2009 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
