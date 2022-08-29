use strict; use warnings;

package DBIx::Connector::Driver::mysql;

use DBIx::Connector::Driver;

our $VERSION = '0.58';
our @ISA = qw( DBIx::Connector::Driver );

sub _connect {
    my ($self, $dbh) = @_;
    $dbh->{mysql_auto_reconnect} = 0;
    $dbh;
}

sub savepoint {
    my ($self, $dbh, $name) = @_;
    $dbh->do("SAVEPOINT $name");
}

sub release {
    my ($self, $dbh, $name) = @_;
    $dbh->do("RELEASE SAVEPOINT $name");
}

sub rollback_to {
    my ($self, $dbh, $name) = @_;
    $dbh->do("ROLLBACK TO SAVEPOINT $name");
}

1;

__END__

=head1 NAME

DBIx::Connector::Driver::mysql - MySQL-specific connection interface

=head1 DESCRIPTION

This subclass of L<DBIx::Connector::Driver|DBIx::Connector::Driver> provides
MySQL-specific implementations of the following methods:

=over

=item C<savepoint>

=item C<release>

=item C<rollback_to>

=back

It also modifies the connection attributes as follows:

=over

=item C<mysql_auto_reconnect>

Will always be set to false. This is to prevent MySQL's auto-reconnection
feature from interfering with DBIx::Connector's auto-reconnection
functionality in C<fixup> mode.

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
