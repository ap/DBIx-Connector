package DBIx::Connection::Driver::mysql;

use strict;
use warnings;
use base 'DBIx::Connection::Driver';
use mro 'c3';

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

=head1 Name

DBIx::Connection::Driver - MySQL-specific connection interface

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
