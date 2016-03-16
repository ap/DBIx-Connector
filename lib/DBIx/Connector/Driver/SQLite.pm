package DBIx::Connector::Driver::SQLite;

use strict;
use warnings;
use base 'DBIx::Connector::Driver';
our $VERSION = '0.56';

sub _connect {
    my ($self, $dbh, $dsn, $username, $password, $attrs) = @_;

    my ($x, $y, $z) = split /[.]/ => $dbh->{sqlite_version};
    $self->{_sqlite_is_new_enough} = (
        $x > 3 || (
            $x == 3 && ($y > 6 || (
                $y == 6 && $z >= 8
            ))
        )
    ) ? 1 : 0;
    return $dbh;
}

sub savepoint {
    my ($self, $dbh, $name) = @_;
    return unless $self->{_sqlite_is_new_enough};
    $dbh->do("SAVEPOINT $name");
}

sub release {
    my ($self, $dbh, $name) = @_;
    return unless $self->{_sqlite_is_new_enough};
    $dbh->do("RELEASE SAVEPOINT $name");
}

sub rollback_to {
    my ($self, $dbh, $name) = @_;
    return unless $self->{_sqlite_is_new_enough};
    $dbh->do("ROLLBACK TO SAVEPOINT $name");
}

1;
__END__

=head1 Name

DBIx::Connector::Driver::SQLite - SQLite-specific connection interface

=head1 Description

This subclass of L<DBIx::Connector::Driver|DBIx::Connector::Driver> provides
SQLite-specific implementations of the following methods:

=over

=item C<savepoint>

=item C<release>

=item C<rollback_to>

=back

Note that they only work with SQLite 3.6.8 or higher; older versions of SQLite
will fallback on the exception-throwing implementation of these methods in
L<DBIx::Connector::Driver|DBIx::Connector::Driver>.

=head1 Authors

This module was written and is maintained by:

=over

=item David E. Wheeler <david@kineticode.com>

=back

=head1 Copyright and License

Copyright (c) 2009-2013 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
