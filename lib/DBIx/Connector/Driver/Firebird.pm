use strict; use warnings;

package DBIx::Connector::Driver::Firebird;

use DBIx::Connector::Driver;

our $VERSION = '0.57';
our @ISA = qw( DBIx::Connector::Driver );

sub savepoint {
    my ($self, $dbh, $name) = @_;
    $dbh->do("SAVEPOINT $name");
}

# Firebird automatically erases a savepoint when you create another
# one with the same name.
sub release { 1 }

sub rollback_to {
    my ($self, $dbh, $name) = @_;
    $dbh->do("ROLLBACK TO $name");
}

1;

__END__

=head1 Name

DBIx::Connector::Driver::Firebird - Firebird-specific connection
interface

=head1 Description

This subclass of L<DBIx::Connector::Driver|DBIx::Connector::Driver>
provides Firebird-specific implementations of the following methods:

=over

=item C<savepoint>

=item C<release>

=item C<rollback_to>

=back

=head1 Authors

This module was written by:

=over

=item David E. Wheeler <david@kineticode.com>

=item Stefan Suciu <stefbv70@gmail.com>

=back

It is based on code written by:

=over

=item Matt S. Trout <mst@shadowcatsystems.co.uk>

=item Peter Rabbitson <rabbit+dbic@rabbit.us>

=back

=head1 Copyright and License

Copyright (c) 2009-2016 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
