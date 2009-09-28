package DBIx::Connection;

use 5.6.2;
use strict;
use warnings;
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
    my $dbh = $self->_verify_pid or return $self->_connect;
    return $self->connected ? $dbh : $self->_connect;
}

# Just like dbh(), except it doesn't ping the server.
sub _dbh {
    my $self = shift;
    $self->_verify_pid || $self->_connect;
}

sub _verify_pid {
    my $self = shift;
    my $dbh = $self->{_dbh} or return;
    if ( defined $self->{_tid} && $self->{_tid} != threads->tid ) {
        return;
    } elsif ( $self->{_pid} != $$ ) {
        $dbh->{InactiveDestroy} = 1;
        return;
    }
    return $dbh;
}

sub connected {
    my $dbh = shift->{_dbh} or return;
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
    my $dbh  = $self->_dbh;

    my $wantarray = wantarray;
    my @result = eval { _exec( $dbh, $code, $wantarray, @_) };

    if (my $err = $@) {
        die $err if $self->connected;
        # Not connected. Try again.
        @result = _exec( $self->_connect, $code, @_ );
    }

    return $wantarray ? @result : $result[0];
}

sub txn {
    my $self = shift;
    my $code = shift;
    my $dbh  = $self->_dbh;

    my $wantarray = wantarray;
    my @result;
    eval {
        $dbh->begin_work;
        @result = _exec( $dbh, $code, $wantarray, @_);
        $dbh->commit;
    };

    if (my $err = $@) {
        if ($self->connected) {
            $dbh->rollback;
            die $err;
        }
        # Not connected. Try again.
        $dbh = $self->_connect;
        $dbh->begin_work;
        @result = _exec( $dbh, $code, @_ );
        $dbh->commit;
    }

    return $wantarray ? @result : $result[0];
}

sub _exec {
    my ($dbh, $code, $wantarray) = (shift, shift, shift);
    my @result;
    if ($wantarray) {
        @result = $code->($dbh, @_);
    }
    elsif (defined $wantarray) {
        $result[0] = $code->($dbh, @_);
    }
    else {
        # void context.
        $code->($dbh, @_);
    }
    return @result;
}

1;
__END__

=begin comment

Fake-out Module::Build. Delete if it ever changes to support =head1 headers
other than all uppercase.

=head1 NAME

DBIx::Connection - Fast, safe DBI connection management

=end comment

=head1 Name

DBIx::Connection - Fast, safe DBI connection management

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

DBIx::Connection provides a simple interface for fast and safe DBI connection
management. Connecting to a database can be expensive; you don't want your
application to re-connect every time you have to run a query. The efficient
thing to do is to cache database handles and then just fetch them from
the cache as-needed, to save that overhead. This is the core function of
DBIx::Connection.

You might be familiar with L<Apache::DBI|Apache::DBI> and with the
L<DBI|DBI>'s L<C<connect_cached>|DBI/connect_cached> method. DBIx::Connection
serves a similar need, but does a much better job. How is it different? I'm
glad you asked!

=over

=item * Fork Safety

Like Apache::DBI, but unlike C<connect_cached>, DBIx::Connection will return a
new database handle if a new process has been C<fork>ed. This happens all the
time under L<mod_perl|mod_perl>, in L<POE|POE> applications, and elsewhere.

=item * Thread Safety

Unlike Apache::DBI or C<connect_cached>, DBIx::Connection will return a new
database handle if a new thread has been spawned. Like C<fork>ing, spawning a
new thread can break database connections.

=item * Works Anywhere

Unlike Apache::DBI, DBIx::Connection runs anywhere -- inside of mod_perl or
not. Why limit yourself?

=item * Explicit Interface

Again unlike Apache::DBI, DBIx::Connection has an explicit interface. There is
no magical action-at-a-distance crap going on. I've personally diagnosed a few
issues with Apache::DBI's magic, and killed it off in two different
applications in favor of C<connect_cached>. No more.

=item * Optimistic Execution

If you use the C<do> or C<txn> methods, the database handle will be passed
without first pinging the server. For the 99% or more of the time that the
database is just there, you'll save a ton of overhead without the ping.
DBIx::Connection will only connect to the server if a query first fails.

=back

If you're used to Apache::DBI or C<connect_cached>, the simplest thing
to do is to use the C<connect> class method. Just change your calls to

  my $dbh = DBI->connect(@args);

Or:

  my $dbh = DBI->connect_cached(@args);

To:

  my $dbh = DBIx::Connection->connect(@args);

DBIx::Connection will return a cached database handle whenever possible,
making sure that it's C<fork>- and thread-safe and connected to the database.
If you do nothing else, making this switch will save you some headaches.

But the real utility of DBIx::Connection comes from its C<do> and C<txn>
methods. Instead of this:

  my $dbh = DBIx::Connection->connect(@args);
  $dbh->do($query);

What you want to do is this:

  my $conn = DBIx::Connection->new(@args);
  $conn->do(sub {
      my $dbh = shift;
      $dbh->do($query);
  });

The difference is that C<do> will pass the database handle to the code
reference without first checking that the connection is still alive. The vast
majority of the time, the connection will of course still be open. You
therefore save the overhead of an extra query every time you use a cached
handle.

It's only if the code ref dies that C<do> will check the connection. If the
handle is not connected to the database (because the database was restarted,
for example), I<then> C<do> will create a new database handle and execute the
code reference again.

=head1 Class Interface

=head2 Constructor

=head3 C<new>

  my $conn = DBIx::Connection−>new($dsn, $username, $password, \%attr);

Instantiates and returns a new DBIx::Connection objects. The supported
arguments are exactly the same as those supported by the L<DBI|DBI>.

=head2 Class Method

=head3 C<connect>

  my $dbh = DBIx::Connection−>connect($dsn, $username, $password, \%attr);

Returns a cached database handle similar to what you would expect from the
DBI's L<C<connect_cached>|DBI/connect_cached> method -- except that it ensures
that the handle is fork- and thread-safe.

Otherwise, like C<connect_cached>, it ensures that the database connection is
live before returning the handle. If it's not, it will instantiate, cache, and
return a new handle.

This method is provided as syntactic sugar for

  my $dbh = DBIx::Connection->new(@args)->dbh;

And for simplicity for those who just want to switch from Apache::DBI or
C<connect_cached>. Really you want more, though. Read on!

=head1 Instance Interface

=head2 Instance Methods

=head3 C<dbh>

  my $dbh = $conn->dbh;

Returns the connection's database handle. It will use a cached copy of the
handle if the process has not been C<fork>ed or a new thread spawned, and if
the database connection is alive. Otherwise, it ensures that the database
connection is live before returning the handle. If it's not, it will
instantiate, cache, and return a new handle.

=head3 C<connected>

  if ( $conn->connected ) {
      $conn->dbh->do($query);
  }

Returns true if the database handle is connected to the database. You probably
won't need to bother with this method; DBIx::Connection uses it internally to
determine whether or not to create a new connection to the database before
returning a handle from C<dbh>.

=head3 C<disconnect>

  $conn->disconnect;

Disconnects from the database. If a transaction is in process it will be
rolled back. DBIx::Connection uses this method internally in its C<DESTROY>
method to make sure that things are kept tidy.

=head3 C<do>

  my $sth = $conn->do(sub {
      my $dbh = shift;
      $dbh->do($_) for @queries;
      $dbh->prepare($query);
  });

  my @res = $conn->do(sub {
      my ($dbh, @args)
      $dbh->selectrow_array(@args);
  }, $query);

Executes the given code reference, passing in the database handle. Any
additional arguments passed to C<do> will be passed on to the code reference.
In an array context, it will return all the results returned by the code
reference. In a scalar context, it will return the last value returned by the
code reference. And in a void context, it will return C<undef>.

The difference from just using the database handle returned by C<dbh> is that
C<do> does not first check that the connection is still alive. Doing so is an
expensive operation, and by avoiding it, C<do> optimistically expects things
to just work the vast majority of the time.

In the event of a failure, C<do> will re-connect to the database and execute
the code reference a second time. Therefor, the code ref should have no
side-effects outside of the database, as double-execution in the event of a
stale database connection could break something:

  my $count;
  $conn->do(sub { $count++ });
  say $count; # 1 or 2

=head3 C<txn>

 $conn->do(sub {
      my $dbh = shift;
      $dbh->do($_) for @queries;
  });

Just like C<do>, only the execution of the code reference is wrapped in a
transaction. In the event of a failure, the transaction will be rolled back.

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
