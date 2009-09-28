package DBIx::Connection::Driver::Pg;

use strict;
use warnings;
use base 'DBIx::Connection::Driver';

sub savepoint_begin {
    my ($self, $dbh, $name) = @_;
    $dbh->pg_savepoint($name);
}

sub savepoint_release {
    my ($self, $dbh, $name) = @_;
    $dbh->pg_release($name);
}

sub savepoint_rollback {
    my ($self, $dbh, $name) = @_;
    $dbh->pg_rollback_to($name);
}

1;
__END__

=head1 Name

DBIx::Connection::Driver - Database-specific connection interface

=head3 C<savepoint_begin>

=head3 C<savepoint_release>

=head3 C<savepoint_rollback>

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
