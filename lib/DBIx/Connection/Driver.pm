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

sub begin_work {
    my ($self, $dbh) = @_;
    $dbh->begin_work;
}

sub commit {
    my ($self, $dbh) = @_;
    $dbh->commit;
}

sub rollback {
    my ($self, $dbh) = @_;
    $dbh->rollback;
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

=head1 Description

Some of the things that DBIx::Connection does are implemented differently by
different drivers, or the official interface provided by the DBI may not be
implemented for a particular driver. The driver-specific code therefore is
encapsulated in this separate driver class.

Most of the DBI drivers work uniformly, so in most cases the implementation
provided here in DBIx::Connection::Driver will work just fine. It's only when
something is different that a driver subclass needs to be added. In such a
case, the subclass's name is the same as the DBI driver. For example the
driver for DBD::Pg is
L<DBIx::Connection::Driver::Pg|DBIx::Connection::Driver::Pg> and the driver
for DBD::mysql is
L<DBIx::Connection::Driver::mysql|DBIx::Connection::Driver::mysql>.

If you're just a user of DBIx::Connection, you can ignore the driver classes.
DBIx::Connection uses them internally to do its magic, so you needn't worry
about them.

=head1 Interface

In case you need to implement a driver, here's the interface you can modify.

=head2 Constructor

=head3 C<new>

  my $driver = DBIx::Connection::Driver->new( driver => $driver );

Constructs and returns a driver object.

=head3 C<ping>

=head3 C<begin_work>

=head3 C<commit>

=head3 C<rollback>

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
