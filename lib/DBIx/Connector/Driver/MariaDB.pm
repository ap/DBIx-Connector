use strict; use warnings;

package DBIx::Connector::Driver::MariaDB;

use DBIx::Connector::Driver::mysql;

our $VERSION = '0.60';
our @ISA = qw( DBIx::Connector::Driver::mysql );

sub _connect {
    my ($self, $dbh) = @_;
    $dbh->{mariadb_auto_reconnect} = 0;
    $dbh;
}

1;

__END__

=head1 NAME

DBIx::Connector::Driver::MariaDB - MariaDB-specific connection interface

=head1 DESCRIPTION

This subclass of L<DBIx::Connector::Driver::mysql|DBIx::Connector::Driver::mysql>
modifies the connection attributes as follows:

=over

=item C<mariadb_auto_reconnect>

Will always be set to false. This is to prevent MariaDB's auto-reconnection
feature from interfering with DBIx::Connector's auto-reconnection
functionality in C<fixup> mode.

=back

=head1 AUTHORS

This module was written by:

=over

=item Aristotle Pagaltzis <pagaltzis@gmx.de>

=back

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2024 Aristotle Pagaltzis. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
