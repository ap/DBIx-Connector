package DBIx::Connector::Driver::Oracle;

use strict;
use warnings;
use base 'DBIx::Connector::Driver';
our $VERSION = '0.56';

# Note from https://rt.cpan.org/Ticket/Display.html?id=47005:
# DBD::Oracle has some shutdown state in which it will return 1 on ping as
# long as the socket is still open. This however did not guarantee the server
# is any longer in a state to execute queries. So what happened was:
#
# 1) the weird state is reached
# 2) a txn_do takes place and fails on the first sql command
# 3) the code calls ping() and gets a connected reply
# 4) the txn_do is not retried
# 5) ...
# 6) users lose profit

sub ping {
    my ($self, $dbh) = @_;
    eval {
        local $dbh->{RaiseError} = 1;
        $dbh->do('select 1 from dual');
    };
    return $@ ? 0 : 1;
}

sub savepoint {
    my ($self, $dbh, $name) = @_;
    $dbh->do("SAVEPOINT $name");
}

# Oracle automatically releases a savepoint when you start another one with
# the same name.
sub release { 1 }

sub rollback_to {
    my ($self, $dbh, $name) = @_;
    $dbh->do("ROLLBACK TO SAVEPOINT $name");
}

1;
__END__

=head1 Name

DBIx::Connector::Driver::Oracle - Oracle-specific connection interface

=head1 Description

This subclass of L<DBIx::Connector::Driver|DBIx::Connector::Driver> provides
Oracle-specific implementations of the following methods:

=over

=item C<ping>

=item C<savepoint>

=item C<release>

=item C<rollback_to>

=back

=head1 Authors

This module was written and is maintained by:

=over

=item David E. Wheeler <david@kineticode.com>

=back

It is based on code written by:

=over

=item Matt S. Trout <mst@shadowcatsystems.co.uk>

=item Peter Rabbitson <rabbit+dbic@rabbit.us>

=item David Jack Olrik <djo@cpan.org>

=back

=head1 Copyright and License

Copyright (c) 2009-2013 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
