package DBIx::Connector::Driver::SQLite;

use strict;
use warnings;
use base 'DBIx::Connector::Driver';
our $VERSION = '0.35';

BEGIN {
    # Only install support for savepoints if SQLite supports them.
    my ($x, $y, $z) = split /[.]/ => $DBD::SQLite::sqlite_version || 0;
    return unless $x >= 3 && $y >= 6 && $z >= 8;
    eval q{
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
    };
    die $@ if $@;
}

1;
__END__

=head1 Name

DBIx::Connector::Driver::SQLite - SQLite-specific connection interface

=head1 Description

This subclass of L<DBIx::Connector::Driver|DBIx::Connector::Driver> provides
PostgreSQL-specific implementations of the following methods:

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

Copyright (c) 2009-2010 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
