use strict; use warnings;

package DBIx::Connector::Driver::Pg;

use DBIx::Connector::Driver;

our $VERSION = '0.58';
our @ISA = qw( DBIx::Connector::Driver );

sub savepoint {
    my ($self, $dbh, $name) = @_;
    $dbh->pg_savepoint($name);
}

sub release {
    my ($self, $dbh, $name) = @_;
    $dbh->pg_release($name);
}

sub rollback_to {
    my ($self, $dbh, $name) = @_;
    $dbh->pg_rollback_to($name);
}

1;

__END__

=head1 NAME

DBIx::Connector::Driver::Pg - PostgreSQL-specific connection interface

=head1 DESCRIPTION

This subclass of L<DBIx::Connector::Driver|DBIx::Connector::Driver> provides
PostgreSQL-specific implementations of the following methods:

=over

=item C<savepoint>

=item C<release>

=item C<rollback_to>

B<NOTE:> Due to L<a bug|https://rt.cpan.org/Ticket/Display.html?id=100648> in
the implementation of DBD::Pg's C<ping> method, DBD::Pg 3.5.0 or later is
strongly recommended.

=back

=head1 AUTHORS

This module was written by:

=over

=item David E. Wheeler <david@kineticode.com>

=back

It is based on code written by:

=over

=item Matt S. Trout <mst@shadowcatsystems.co.uk>

=item Peter Rabbitson <rabbit+dbic@rabbit.us>

=back

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2009-2013 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
