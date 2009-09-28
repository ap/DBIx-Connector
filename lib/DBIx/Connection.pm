package DBIx::Connection;

use strict;
use 5.6.2;
use DBI '1.605';

our $VERSION = '0.10';

CACHED: {
    our %CACHE;

    sub new {
        my $class = shift;
        my $args = [@_];
        my $key  = do {
            no warnings 'uninitialized';
            # XXX Change in unlikely event the DBI changes this function.
            join "!\001", @_[0..2], DBI::_concat_hash_sorted(
                $_[3], "=\001", ",\001", 0, 0
            )
        };
        return $CACHE{$key} ||= bless { _args => $args, _key => $key } => $class;
    }

    sub DESTROY {
        my $self = shift;
        $self->disconnect if $self->connected;
        delete $CACHE{ $self->{_key} };
    }
}


sub _connect {
    my $self = shift;
    my $dbh = do {
        if ($INC{'Apache/DBI.pm'} && $ENV{MOD_PERL}) {
            local $DBI::connect_via = 'connect'; # Ignore Apache::DBI.
            DBI->connect( @{ $self->{_args} } );
        } else {
            DBI->connect( @{ $self->{_args} } );
        }
    };
    $self->{_pid} = $$;
    $self->{_tid} = threads->tid if $INC{'threads.pm'};
    return $self->{_dbh} = $dbh;
}

sub connect { shift->new(@_)->dbh }

sub dbh {
    my $self = shift;
    my $dbh = $self->{_dbh} or return $self->_connect;

    if ( defined $self->{_tid} && $self->{_tid} != threads->tid ) {
        return $self->_connect;
    } elsif ( $self->{_pid} != $$ ) {
        $dbh->{InactiveDestroy} = 1;
        return $self->_connect;
    } elsif ( ! $self->connected ) {
        return $self->_connect;
    } else {
        return $dbh;
    }
}

sub connected {
    my $self = shift;
    my $dbh = $self->{_dbh} or return;
    return $dbh->{Active} && $dbh->ping;
}

sub disconnect {
    my $self = shift;
    return $self unless $self->connected;
    my $dbh = $self->{_dbh};
    $dbh->rollback unless $dbh->{AutoCommit};
    $dbh->disconnect;
    $self->{_dbh} = undef;
    return $self;
}

sub do {
    my $self = shift;
    my $code = shift;

    my $dbh = $self->{_dbh} || return $code->($self->dbh);

    my @result;
    my $want_array = wantarray;

    eval {
        if ($want_array) {
            @result = $code->($dbh, @_);
        }
        elsif (defined $want_array) {
            $result[0] = $code->($dbh, @_);
        }
        else {
            # void context.
            $code->($dbh, @_);
        }
    };

    # ->connected might unset $@ - copy
    my $exception = $@;
    unless ($exception) { return $want_array ? @result : $result[0] }

    die $exception if $self->connected;

    # We were not connected - reconnect and retry, but let any
    #  exception fall right through this time
    $code->($self->dbh, @_);
}


1;
__END__

=begin comment

Fake-out Module::Build. Delete if it ever changes to support =head1 headers
other than all uppercase.

=head1 NAME

DBIx::Connection - Safe, persistent, cached database handles

=end comment

=head1 Name

DBIx::Connection - Safe, persistent, cached database handles

=head1 Synopsis

  use DBIx::Connection;

  # Fetch a cached DBI handle.
  my $dbh = DBIx::Connection->connect($dsn, $username, $password, \%attr );

  # Fetch a cached connection.
  my $conn = DBIx::Connection->new($dsn, $username, $password, \%attr );

  # Get the handle and do something with it.
  my $dbh  = $conn->dbh;
  $dbh->do('INSERT INTO foo (name) VALUES (?)', undef, 'Fred' );

  # Do something with the handle more efficiently.
  $conn->do(sub {
      my $dbh = shift;
      $dbh->do('INSERT INTO foo (name) VALUES (?)', undef, 'Fred' );
  });

=head1 Description



=head1 Class Interface

=head2 Constructor

=head3 C<new>



=head2 Class Method

=head3 C<connect>



=head1 Instance Interface

=head2 Instance Methods

=head3 C<connect_args>

=head3 C<dbh>




=head3 C<do>



=head3 C<connected>



=head3 C<disconnect>



=head1 See Also

=over

=item * L<DBI|DBI>

=item * L<DBIx::Class|DBIx::Class>

=item * L<Catalyst::Model::DBI|Catalyst::Model::DBI>

=back

=head1 Support

This module is stored in an open GitHub repository,
L<http://github.com/theory/dbix-connection/tree/>. Feel free to fork and
contribute!

Please file bug reports at L<http://github.com/theory/dbix-connectiona/issues/>.

=head1 Authors

=begin comment

Fake-out Module::Build. Delete if it ever changes to support =head1 headers
other than all uppercase.

=head1 AUTHORS

=end comment

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
