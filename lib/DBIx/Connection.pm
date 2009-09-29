package DBIx::Connection;

use 5.6.2;
use strict;
use warnings;
use DBI '1.605';
use DBIx::Connection::Driver;

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
        return $CACHE{$key} ||= bless {
            _args       => $args,
            _key        => $key,
            _savepoints => [],
        } => $class;
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
            local $DBI::connect_via = 'connect'; # Disable Apache::DBI.
            DBI->connect( @{ $self->{_args} } );
        } else {
            DBI->connect( @{ $self->{_args} } );
        }
    };
    $self->{_pid} = $$;
    $self->{_tid} = threads->tid if $INC{'threads.pm'};

    # Grab the driver.
    $self->_set_driver;

    return $self->{_dbh} = $dbh;
}

sub _set_driver {
    my $self = shift;
    my $driver = 'DBIx::Connection::Driver::' . do {
        if (my $dbh = $self->{_dbh}) {
            $dbh->{Driver}{Name};
        } else {
            (DBI->parse_dsn( $self->{_args}[0]))[1];
        }
    };
    eval "require $driver";
    $driver = 'DBIx::Connection::Driver' if $@;
    $self->{_driver} = $driver->new;
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

# Returns true if there is a database handle and the PID and TID have not changed
# and false otherwise.
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
    my $self = shift;
    return unless $self->_seems_connected;
    my $dbh = $self->{_dbh} or return;
    #be on the safe side
    local $dbh->{RaiseError} = 1;
    return $self->{_driver}->ping($dbh);
}

# Returns true if there is a database handle and the PID and TID have not changed
# and the handle's Active attribute is true.
sub _seems_connected {
    my $self = shift;
    my $dbh = $self->{_dbh} or return;
    return unless $self->_verify_pid;
    return $dbh->{Active};
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

    my @ret;
    my $wantarray = wantarray;
    if ($self->{_in_do} || $self->{_in_txn}) {
        @ret = _exec( $dbh, $code, $wantarray, @_);
        return wantarray ? @ret : $ret[0];
    }

    local $self->{_in_do} = 1;
    @ret = eval { _exec( $dbh, $code, $wantarray, @_) };

    if (my $err = $@) {
        die $err if $self->connected;
        # Not connected. Try again.
        @ret = _exec( $self->_connect, $code, @_ );
    }

    return $wantarray ? @ret : $ret[0];
}

sub txn_do {
    my $self = shift;
    my $code = shift;
    my $dbh  = $self->_dbh;

    my $wantarray = wantarray;
    my @ret;

    if ($self->{_in_txn}) {
        @ret = _exec( $dbh, $code, $wantarray, @_);
        return $wantarray ? @ret : $ret[0];
    }

    local $self->{_in_do} = 1;
    local $self->{_in_txn} = 1;

    eval {
        $dbh->begin_work;
        @ret = _exec( $dbh, $code, $wantarray, @_);
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
        @ret = _exec( $dbh, $code, $wantarray, @_);
        $dbh->commit;
    }

    return $wantarray ? @ret : $ret[0];
}

sub svp_do {
    my $self = shift;
    my $code = shift;
    my $dbh  = $self->_dbh;

    unless ($self->{_in_txn}) {
        # Gotta have a transaction.
        return $self->txn_do( sub { $self->svp_do($code) } );
    }

    local $self->{_in_svp} = 1;

    my @ret;
    my $wantarray = wantarray;

    eval {
        $self->savepoint;
        @ret = _exec( $dbh, $code, $wantarray, @_);
        $self->release;
    };

    if (my $err = $@) {
        # If we died, there is nothing to be done.
        if ($self->connected) {
            $self->rollback_to;
            $self->release;
        }
        die $err;
    }

    return $wantarray ? @ret : $ret[0];
}

sub savepoint {
    my ($self, $name) = @_;
    my $dbh = $self->{_dbh}
        or die 'Savepoints cannot be used outside a transaction';
    die 'Savepoints cannot be used outside a transaction'
        if $dbh->{AutoCommit};

    $name = 'savepoint_' . scalar @{ $self->{_savepoints} }
        unless defined $name;
    push @{ $self->{_savepoints} }, $name;
    return $self->{_driver}->savepoint($dbh, $name);
}

sub release {
    my ($self, $name) = @_;
    my $dbh = $self->{_dbh}
        or die 'Savepoints cannot be used outside a transaction';
    die 'Savepoints cannot be used outside a transaction'
        if $dbh->{AutoCommit};

    if (defined $name) {
        die "Savepoint '$name' does not exist"
            unless grep { $_ eq $name } @{ $self->{_savepoints} };
        # Dig through the stack until we find the one we are releasing. This
        # keeps the stack up to date.
        my $svp;
        do { $svp = pop @{ $self->{_savepoints} } } while $svp ne $name;
    } else {
        $name = pop @{ $self->{_savepoints} };
    }
    return $self->{_driver}->release($dbh, $name);
}

sub rollback_to {
    my ($self, $name) = @_;
    my $dbh = $self->{_dbh}
        or die 'Savepoints cannot be used outside a transaction';
    die 'Savepoints cannot be used outside a transaction'
        if $dbh->{AutoCommit};

    if (defined $name) {
        # If they passed us a name, verify that it exists in the stack
        die "Savepoint '$name' does not exist"
            unless grep { $_ eq $name } @{ $self->{_savepoints} };

        # Dig through the stack until we find the one we are releasing. This
        # keeps the stack up to date.
        while (my $s = pop @{ $self->{_savepoints} }) {
            last if $s eq $name;
        }

        # Add the savepoint back to the stack, as a rollback doesn't remove the
        # named savepoint, only everything after it.
        push @{ $self->{_savepoints} }, $name;
    } else {
        # We'll assume they want to rollback to the last savepoint
        $name = $self->{_savepoints}->[-1];
    }
    return $self->{_driver}->rollback_to($dbh, $name);
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
thing to do is to cache database handles and then just fetch them from the
cache as needed in order to minimize that overhead. DBI database handle
caching is the core function of DBIx::Connection.

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

DBIx::Connection has an explicit interface. There is none of the magical
action-at-a-distance crap that Apache::DBI is guilty of. I've personally
diagnosed a few issues with Apache::DBI's magic, and killed it off in two
different applications in favor of C<connect_cached>. No more.

=item * Optimistic Execution

If you use the C<do> or C<txn_do> methods, the database handle will be passed
without first pinging the server. For the 99% or more of the time when the
database is just there, you'll save a ton of overhead without the ping.
DBIx::Connection will only connect to the server if a query fails.

=back

=head2 Basic Usage

If you're used to Apache::DBI or C<connect_cached>, the simplest thing to do
is to use the C<connect> class method. Just change your calls from

  my $dbh = DBI->connect(@args);

Or:

  my $dbh = DBI->connect_cached(@args);

To:

  my $dbh = DBIx::Connection->connect(@args);

DBIx::Connection will return a cached database handle whenever possible,
making sure that it's C<fork>- and thread-safe and connected to the database.
If you do nothing else, making this switch will save you some headaches.

But the real utility of DBIx::Connection comes from its C<do> and C<txn_do>
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

Simple, huh?

=head1 Interface

And now for the nitty-gritty.

=head2 Constructor

=head3 C<new>

  my $conn = DBIx::Connection−>new($dsn, $username, $password, \%attr);

Returns a cached DBIx::Connection object. The supported arguments are exactly
the same as those supported by the L<DBI|DBI>, and these also determine the
connection object to be returned. If C<new> (or C<connect>) has been called
before with exactly the same arguments (including the contents of the
attributes hash reference), then the same connection object will be returned.
Otherwise, a new object will be instantiated, cached, and returned.

Caching connections can be useful in some applications, but it can also cause
problems, such as too many connections, and so should be used with care. In
particular, avoid changing the attributes of a database handle returned from
C<dbh> because it will affect other code that may be using the same
connection.

As with the L<DBI|DBI>'s L<C<connect_cached>|DBI/connect_cached>, Where
multiple separate parts of a program are using DBIx::Connection to connect to
the same database with the same (initial) attributes, it is a good idea to add
a private attribute to the the C<new> call to effectively limit the scope of
the caching. For example:

  DBIx::Connection−>>new(..., { private_foo_cachekey => "Bar", ... });

Connections returned from that call will only be returned by other calls to
C<new> or C<connect> elsewhere in the code if those other calls also pass in
the same attribute values, including the private one. (The use of
"private_foo_cachekey" here is an example; you can use any attribute name with
a "private_" prefix.)

Taking that one step further, you can limit a particular connection to that
one place in the code by setting the private attribute to a unique value for
that place:

  DBIx::Connection−>new(..., { private_foo_cachekey => __FILE__.__LINE__, ... });

By using a private attribute you still get connection caching for the
individual calls to C<new> but, by making separate database connections for
separate parts of the code, the database handles are isolated from any
attribute changes made to other handles.

=head2 Class Method

=head3 C<connect>

  my $dbh = DBIx::Connection−>connect($dsn, $username, $password, \%attr);

Returns a cached database handle similar to what you would expect from the
DBI's L<C<connect_cached>|DBI/connect_cached> method -- except that it ensures
that the handle is C<fork>- and thread-safe.

Otherwise, like C<connect_cached>, it ensures that the database connection is
live before returning the handle. If it's not, it will instantiate, cache, and
return a new handle.

This method is provided as syntactic sugar for:

  my $dbh = DBIx::Connection->new(@args)->dbh;

So be sure to carefully read the documentation for C<new>, as well.
DBIx::Connectionprovides this method for those who just want to switch from
Apache::DBI or C<connect_cached>. Really you want more, though. Trust me. Read
on!

=head2 Instance Methods

=head3 C<dbh>

  my $dbh = $conn->dbh;

Returns the connection's database handle. It will use a cached copy of the
handle if the process has not been C<fork>ed or a new thread spawned, and if
the database connection is alive. Otherwise, it will instantiate, cache, and
return a new handle.

=head3 C<connected>

  if ( $conn->connected ) {
      $conn->dbh->do($query);
  }

Returns true if the database handle is connected to the database and false if
it's not. You probably won't need to bother with this method; DBIx::Connection
uses it internally to determine whether or not to create a new connection to
the database before returning a handle from C<dbh>.

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
  }, $query, undef, $value);

Executes the given code reference, passing in the database handle. Any
additional arguments passed to C<do> will be passed on to the code reference.
In an array context, it will return all the results returned by the code
reference. In a scalar context, it will return the last value returned by the
code reference. And in a void context, it will return C<undef>.

The difference from just using the database handle returned by C<dbh> is that
C<do> does not first check that the connection is still alive. Doing so is an
expensive operation, and by avoiding it, C<do> optimistically expects things
to just work the vast majority of the time. (It does make sure that the handle
is C<fork>- and thread-safe, however.)

In the event of a failure due to a broken database connection, C<do> will
re-connect to the database and execute the code reference a second time.
Therefore, the code ref should have no side-effects outside of the database,
as double-execution in the event of a stale database connection could break
something:

  my $count;
  $conn->do(sub { $count++ });
  say $count; # 1 or 2

=head3 C<txn_do>

 $conn->txn_do(sub {
      my $dbh = shift;
      $dbh->do($_) for @queries;
  });

Just like C<do>, only the execution of the code reference is wrapped in a
transaction. In the event of a failure, the transaction will be rolled back.

=head3 C<svp_do>

  $conn->txn_do(sub {
      $conn->svp_do(sub {
          my $dbh = shift;
          $dbh->do($expensive_query);
          $conn->svp_do(sub {
              shift->do($other_query);
          });
      });
  });

Executes code within the context of a savepoint, if your database supports it.
Savepoints must be executed within the context of a transaction; if you don't
call C<svp_do> inside a call to C<txn_do>, C<svp_do> will it for you.

You can think of savepoints as a kind of subtransaction. What this means is
that you can nest your savepoints and recover from failures deeper in the nest
without throwing out all changes higher up in the nest. For example:

  $conn->txn_do(sub {
      my $dbh = shift;
      $dbh->do('INSERT INTO table1 VALUES (1)');
      eval {
          $conn->svp_do(sub {
              shift->do('INSERT INTO table1 VALUES (2)');
              die 'OMGWTF?';
          });
      };
      warn "Savepoint failed\n" if $@;
      $dbh->do('INSERT INTO table1 VALUES (3)');
  });

This transaction will insert the values 1 and 3, but not 2.

  $conn->txn_do(sub {
      my $dbh = shift;
      $dbh->do('INSERT INTO table1 VALUES (4)');
      $conn->svp_do(sub {
          shift->do('INSERT INTO table1 VALUES (5)');
      });
  });

This transaction will insert both 3 and 4.

=head3 C<savepoint>



=head3 C<release>



=head3 C<rollback_to>



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

=item Tim Bunce <http://tim.bunce.name>

=item Brandon Black <blblack@gmail.com>

=item Matt S. Trout <mst@shadowcatsystems.co.uk>

=item Alex Pavlovic <alex.pavlovic@taskforce-1.com>

=back

=head1 Copyright and License

Copyright (c) 2009 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
