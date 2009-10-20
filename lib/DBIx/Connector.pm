package DBIx::Connector;

use 5.6.2;
use strict;
use warnings;
use DBI '1.605';
use DBIx::Connector::Driver;

our $VERSION = '0.20';

sub new {
    my $class = shift;
    my $args = [@_];
    bless {
        _args      => $args,
        _svp_depth => 0,
    } => $class;
}

sub DESTROY {
    shift->disconnect;
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

    # Set the driver.
    $self->driver;

    return $self->{_dbh} = $dbh;
}

sub driver {
    my $self = shift;
    return $self->{driver} if $self->{driver};

    my $driver = do {
        if (my $dbh = $self->{_dbh}) {
            $dbh->{Driver}{Name};
        } else {
            (DBI->parse_dsn( $self->{_args}[0]))[1];
        }
    };
    $self->{driver} = DBIx::Connector::Driver->new( $driver );
}

sub connect { shift->new(@_)->dbh }

sub dbh {
    my $self = shift;
    my $dbh = $self->_seems_connected or return $self->_connect;
    return $dbh if $self->{_in_run};
    return $self->connected ? $dbh : $self->_connect;
}

# Just like dbh(), except it doesn't ping the server.
sub _dbh {
    my $self = shift;
    $self->_seems_connected || $self->_connect;
}

sub connected {
    my $self = shift;
    return unless $self->_seems_connected;
    my $dbh = $self->{_dbh} or return;
    #be on the safe side
    local $dbh->{RaiseError} = 1;
    return $self->driver->ping($dbh);
}

# Returns true if there is a database handle and the PID and TID have not changed
# and the handle's Active attribute is true.
sub _seems_connected {
    my $self = shift;
    my $dbh = $self->{_dbh} or return;
    if ( defined $self->{_tid} && $self->{_tid} != threads->tid ) {
        return;
    } elsif ( $self->{_pid} != $$ ) {
        # We've forked, so prevent the parent process handle from touching the
        # DB on DESTROY. Here in the child process, that could really screw
        # things up.
        $dbh->{InactiveDestroy} = 1;
        return;
    }
    return $dbh->{Active} ? $dbh : undef;
}

sub disconnect {
    my $self = shift;
    return $self unless $self->connected;
    my $dbh = $self->{_dbh};
    $self->driver->rollback($dbh) unless $dbh->{AutoCommit};
    $dbh->disconnect;
    $self->{_dbh} = undef;
    return $self;
}

sub run {
      my $self = shift;
    my $mode = ref $_[0] eq 'CODE' ? 'no_ping' : shift;
    return $self->_fixup_run(@_) if $mode eq 'fixup';
    my $dbh = $mode eq 'ping' ? $self->dbh : $self->_dbh;
    return $self->_run($dbh, @_);
  }

sub _run {
    my $self = shift;
    my $dbh  = shift;
    my $code = shift;
    local $self->{_in_run} = 1;
    my $wantarray = wantarray;
    my @ret = _exec( $dbh, $code, $wantarray, @_ );
    return $wantarray ? @ret : $ret[0];
}

sub _fixup_run {
    my $self = shift;
    my $code = shift;
    my $dbh  = $self->_dbh;

    my @ret;
    my $wantarray = wantarray;
    if ($self->{_in_run} || !$dbh->{AutoCommit}) {
        @ret = _exec( $dbh, $code, $wantarray, @_ );
        return wantarray ? @ret : $ret[0];
    }

    local $self->{_in_run} = 1;
    @ret = eval { _exec( $dbh, $code, $wantarray, @_ ) };

    if (my $err = $@) {
        die $err if $self->connected;
        # Not connected. Try again.
        @ret = _exec( $self->_connect, $code, $wantarray, @_ );
    }

    return $wantarray ? @ret : $ret[0];
}

sub txn {
    my $self = shift;
    my $mode = ref $_[0] eq 'CODE' ? 'no_ping' : shift;
    return $self->_txn_fixup_run(@_) if $mode eq 'fixup';
    my $dbh = $mode eq 'ping' ? $self->dbh : $self->_dbh;
    return $self->_txn_run($dbh, @_);
}

sub _txn_run {
    my $self   = shift;
    my $dbh    = shift;
    my $code   = shift;
    my $driver = $self->driver;

    my $wantarray = wantarray;
    my @ret;
    local $self->{_in_run}  = 1;

    unless ($dbh->{AutoCommit}) {
        @ret = _exec( $dbh, $code, $wantarray, @_ );
        return $wantarray ? @ret : $ret[0];
    }

    eval {
        $driver->begin_work($dbh);
        @ret = _exec( $dbh, $code, $wantarray, @_ );
        $driver->commit($dbh);
    };

    if (my $err = $@) {
        $driver->rollback($dbh);
        die $err;
    }

    return $wantarray ? @ret : $ret[0];
}

sub _txn_fixup_run {
    my $self   = shift;
    my $code   = shift;
    my $dbh    = $self->_dbh;
    my $driver = $self->driver;

    my $wantarray = wantarray;
    my @ret;
    local $self->{_in_run}  = 1;

    unless ($dbh->{AutoCommit}) {
        @ret = _exec( $dbh, $code, $wantarray, @_ );
        return $wantarray ? @ret : $ret[0];
    }

    eval {
        $driver->begin_work($dbh);
        @ret = _exec( $dbh, $code, $wantarray, @_ );
        $driver->commit($dbh);
    };

    if (my $err = $@) {
        if ($self->connected) {
            $driver->rollback($dbh);
            die $err;
        }
        # Not connected. Try again.
        $dbh = $self->_connect;
        eval {
            $driver->begin_work($dbh);
            @ret = _exec( $dbh, $code, $wantarray, @_ );
            $driver->commit($dbh);
        };
        if (my $err = $@) {
            $driver->rollback($dbh);
            die $err;
        }
    }

    return $wantarray ? @ret : $ret[0];
}

# XXX Should we make svp_run ignore databases that don't support savepoints,
# basically making it work just like txn_fixup_run for those platforms?

sub svp {
    my $self = shift;
    my $mode = ref $_[0] eq 'CODE' ? 'no_ping' : shift;
    my $code = shift;
    my $dbh  = $self->{_dbh};

    # Gotta have a transaction.
    if (!$dbh || $dbh->{AutoCommit}) {
        my @args = @_;
        return $self->txn( $mode => sub { $self->svp( $code, @args ) } );
    }

    my @ret;
    my $wantarray = wantarray;
    my $name = "savepoint_$self->{_svp_depth}";
    ++$self->{_svp_depth};

    eval {
        $self->savepoint($name);
        @ret = _exec( $dbh, $code, $wantarray, @_ );
        $self->release($name);
    };
    --$self->{_svp_depth};

    if (my $err = $@) {
        # If we died, there is nothing to be done.
        if ($self->connected) {
            $self->rollback_to($name);
            $self->release($name);
        }
        die $err;
    }

    return $wantarray ? @ret : $ret[0];
}

PROXY: {
    package DBIx::Connector::Proxy;
    sub new {
        my ($class, $conn, $mode) = @_;
        require Carp && Carp::croak('Missing required mode argument')
            unless $mode;
        require Carp && Carp::croak(qq{Invalid mode: "$mode"})
            unless $mode =~ /^(?:fixup|(?:no_)?ping)$/;
        bless {
            conn => $conn,
            mode => $mode,
        } => $class;
    }

    sub mode { shift->{mode} }
    sub conn { shift->{conn} }
    sub dbh  { shift->{conn}->dbh(@_) }

    sub run {
        my $self = shift;
        $self->{conn}->run( $self->{mode} => @_ );
    }

    sub txn {
        my $self = shift;
        $self->{conn}->txn( $self->{mode} => @_ );
    }

    sub svp {
        my $self = shift;
        $self->{conn}->svp( $self->{mode} => @_ );
    }
}

sub with {
    DBIx::Connector::Proxy->new(@_);
}

# Deprecated methods.
sub do {
    require Carp;
    Carp::cluck('DBIx::Connctor::do() is deprecated; use fixup_run() instead');
    shift->_fixup_run(@_);
}

sub txn_do {
    require Carp;
    Carp::cluck('txn_do() is deprecated; use txn_fixup_run() instead');
    shift->_txn_fixup_run(@_);
}

sub svp_do {
    require Carp;
    Carp::cluck('svp_do() is deprecated; use svp_run() instead');
    shift->svp(fixup => @_);
}

sub clear_cache {
    require Carp;
    Carp::cluck('clear_cache() is deprecated; DBIx::Connector no longer uses caching');
    shift;
}

sub savepoint {
    my ($self, $name) = @_;
    return $self->driver->savepoint($self->{_dbh}, $name);
}

sub release {
    my ($self, $name) = @_;
    return $self->driver->release($self->{_dbh}, $name);
}

sub rollback_to {
    my ($self, $name) = @_;
    return $self->driver->rollback_to($self->{_dbh}, $name);
}

sub _exec {
    my ($dbh, $code, $wantarray) = (shift, shift, shift);
    local $_ = $dbh;
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

DBIx::Connector - Fast, safe DBI connection and transaction management

=end comment

=head1 Name

DBIx::Connector - Fast, safe DBI connection and transaction management

=head1 Synopsis

  use DBIx::Connector;

  # Create a connection.
  my $conn = DBIx::Connector->new($dsn, $username, $password, \%attr );

  # Get the database handle and do something with it.
  my $dbh  = $conn->dbh;
  $dbh->do('INSERT INTO foo (name) VALUES (?)', undef, 'Fred' );

  # Do something with the handle more efficiently.
  $conn->run( fixup => sub {
      $_->do('INSERT INTO foo (name) VALUES (?)', undef, 'Fred' );
  });

=head1 Description

DBIx::Connector provides a simple interface for fast and safe DBI connection
and transaction management. Connecting to a database can be expensive; you
don't want your application to re-connect every time you need to run a query.
The efficient thing to do is to hang on to a database handle to maintain a
connection to the database in order to minimize that overhead. DBIx::Connector
lets you do that without having to worry about dropped or corrupted
connections.

You might be familiar with L<Apache::DBI|Apache::DBI> and with the
L<DBI|DBI>'s L<C<connect_cached()>|DBI/connect_cached> constructor.
DBIx::Connector serves a similar need, but does a much better job. How is it
different? I'm glad you asked!

=over

=item * Fork Safety

Like Apache::DBI, but unlike C<connect_cached()>, DBIx::Connector will return
a new database handle if a new process has been C<fork>ed. This happens all
the time under L<mod_perl|mod_perl>, in L<POE|POE> applications, and
elsewhere.

=item * Thread Safety

Unlike Apache::DBI or C<connect_cached()>, DBIx::Connector will return a new
database handle if a new thread has been spawned. As with C<fork>ing, spawning
a new thread can break database connections.

=item * Works Anywhere

Unlike Apache::DBI, DBIx::Connector runs anywhere -- inside of mod_perl or
not. Why limit yourself?

=item * Explicit Interface

DBIx::Connector has an explicit interface. There is none of the magical
action-at-a-distance crap that Apache::DBI is guilty of, and no global
caching. I've personally diagnosed a few issues with Apache::DBI's magic, and
killed it off in two different applications in favor of C<connect_cached()>,
only to be tripped up by other gotchas. No more.

=item * Optimistic Execution

If you use C<run()> and C<txn()>, the database handle will be passed without
first pinging the server. For the 99% or more of the time when the database is
just there, you'll save a ton of overhead without the ping.

=back

DBIx::Connector's other feature is transaction management. Borrowing from
L<DBIx::Class|DBIx::Class>, DBIx::Connector offers an interface that
efficiently handles the scoping of database transactions so that you needn't
worry about managing the transaction yourself. Even better, it offers an
interface for savepoints if your database supports them. Within a transaction,
you can scope savepoints to behave like subtransactions, so that you can save
some of your work in a transaction even if some of it fails. See
L<C<txn()>|/"txn"> and L<C<svp()>|/"svp"> for the goods.

=head2 Usage

Unlike L<Apache::DBI|Apache::DBI> and L<C<connect_cached()>|DBI/connect_cached>,
DBIx::Connector doesn't cache database handles. Rather, for a given
connection, it makes sure that the connection just there whenever you want it,
to the extent possible. The upshot is that it's safe to create a connection
and then keep it around for as long as you need it, like so:

  my $conn = DBI->connect(@args);

You can store this somewhere in your app where you can easily access it, and
for as long as it remains in scope, it will try its hardest to maintain a
database connection. Even across C<fork>s and new threads, and even calls to
C<< $conn->dbh->disconnect >>. When you don't need it anymore, let it go out
of scope and the database connection will be closed.

The upshot is that your code is responsible for hanging onto a connection for
as long as it needs it. There is no magical connection caching like in
L<Apache::DBI|Apache::DBI> and L<C<connect_cached()>|DBI/connect_cached>.

=head3 Execution Methods

The real utility of DBIx::Connector comes from the use of the execution
methods, L<C<run()>|/"run">, L<C<txn()>|/"txn">, or L<C<svp()>|/"svp">.
Instead of this:

  $conn->dbh->do($query);

Try this:

  $conn->run(sub { $_->do($query) });

The difference is that the C<run()> optimistically assumes that an existing
database handle is connected and executes the code reference without pinging
the database. The vast majority of the time, the connection will of course
still be open. You therefore save the overhead of a ping query every time you
use C<run()> (or C<txn()>).

Of course, if a block passed to C<run()> dies because the DBI isn't actually
connected to the database you'd need to catch that failure and try again.
DBIx::Connection provides a way to overcome this issue: connection modes.

=head3 Connection Modes

When calling L<C<run()>|/"run">, L<C<txn()>|/"txn">, or L<C<svp()>|/"svp">,
an optional first argument can be used to specify a connection mode.
The supported modes are:

=over

=item * C<ping>

=item * C<fixup>

=item * C<no_ping>

=back

Use them like so:

  $conn->run( ping => sub { $_->do($query) } );

In C<ping> mode, C<run()> will ping the database I<before> running the block.
This is similar to what L<Apache::DBI|Apache::DBI> and L<DBI|DBI>'s
L<C<connect_cached()>|DBI/connect_cached> do to check the database connection
connected, and is the safest way to do so. If the ping fails, DBIx::Connection
will attempt to reconnect to the database before executing the block. However,
C<ping> mode does impose the overhead of the C<ping> ever time you use it.

In C<fixup> mode, DBIx::Connector executes the block without pinging the
database. But in the event the block throws an exception, DBIx::Connector will
reconnect to the database and re-execute the block if the database handle is
no longer connected. Therefore, the code reference should have B<no
side-effects outside of the database,> as double-execution in the event of a
stale database connection could break something:

  my $count;
  $conn->run( fixup => sub { $count++ });
  say $count; # may be 1 or 2

C<fixup> is the most efficient connection mode. If you're confident that the
code block will have no deleterious side-effects if run twice, this is the
best option to choose. If you decide that your code block is likely to have
too many side-effects to execute more than once, you can simply switch to
C<ping> mode.

The default is C<no_ping>, so you likely won't ever use it directly, and isn't
recommended in any event.

Simple, huh? Better still, go for the transaction management in
L<C<txn()>|/"txn"> and the savepoint management in L<C<svp()>|/"svp">. You
won't be sorry, I promise.

=head1 Interface

And now for the nitty-gritty.

=head2 Constructor

=head3 C<new>

  my $conn = DBIx::Connector->new($dsn, $username, $password, \%attr);

Constructs and returns a DBIx::Connector object. The supported arguments are
exactly the same as those supported by the L<DBI|DBI>.

=head2 Class Method

=head3 C<connect>

  my $dbh = DBIx::Connector->connect($dsn, $username, $password, \%attr);

Syntactic sugar for:

  my $dbh = DBIx::Connector->new(@args)->dbh;

Though there's probably not much point in that, as you'll generally want to
hold on to the DBIx::Connector object. Otherwise you'd just use the
L<DBI|DBI>, no?

=head2 Instance Methods

=head3 C<dbh>

  my $dbh = $conn->dbh;

Returns the connection's database handle. It will use a an existing handle if
there is one, the process has not been C<fork>ed or a new thread spawned, and
if the database is pingable. Otherwise, it will instantiate, cache, and return
a new handle.

When called from blocks passed to L<C<run()>|/"run">, L<C<txn()>|/"txn">, and
L<C<svp()>|/"svp">, C<dbh()> assumes that the pingability of the database is
handled by those methods and skips the C<ping()>. Otherwise, it performs all
the same validity checks. The upshot is that it's safe to call C<dbh()> inside
those blocks without the overhead of multiple C<ping>s. Indeed, it's
preferable to do so if you're doing lots of non-database processing in those
blocks.

=head3 C<run>

  $conn->run( ping => sub { $_->do($query) } );

Simply executes the block, setting C<$_> to and passing in the database
handle. Any other arguments passed are passed as extra arguments to the block:

  my @res = $conn->run(sub {
      my ($dbh, @args) = @_;
      $dbh->selectrow_array(@args);
  }, $query, $sql, undef, $value);

An optional first argument sets the connection mode, and may be one of
C<ping>, C<fixup>, or C<no_ping> (the default). See L</"Connection Modes"> for
further explication.

For convenience, you can nest calls to C<run()> (or C<txn()>), although the
connection mode applies only to the outer-most block method call.

  $conn->txn(fixup => sub {
      my $dbh = shift;
      $dbh->do($_) for @queries;
      $conn->run(sub {
          $_->do($expensive_query);
          $conn->txn(sub {
              $_->do($another_expensive_query);
          });
      });
  });

All code executed inside the top-level call to C<txn()> will be executed in a
single transaction. If you'd like subtransactions, see L<C<svp()>|/svp>.

It's preferable to use C<dbh()> to fetch the database handle from within the
block if your code is doing lots of non-database stuff (shame on you!):

  $conn->run(ping => sub {
      parse_gigabytes_of_xml(); # Get this out of the transaction!
      $conn->dbh->do($query);
  });

The reason for this is the C<dbh()> will better ensure that the database
handle is active and C<fork>- and thread-safe, although it will never
C<ping()> the database when called from inside a C<run()>, C<txn()> or
C<svp()> block.

=head3 C<txn>

  my $sth = $conn->txn( fixup => sub { $_->do($query) } );

Starts a transaction, executes the block block, setting C<$_> to and passing
in the database handle, and commits the transaction. If the block throws an
exception, the transaction will be rolled back and the exception re-thrown.

An optional first argument sets the connection mode, and may be one of
C<ping>, C<fixup>, or C<no_ping> (the default). In the case of C<fixup> mode,
this means that the transaction block will be re-executed for a new connection
if the database handle is no longer connected. In such a case, a second
exception from the code block will cause the transaction to be rolled back and
the exception re-thrown. See L</"Connection Modes"> for further explication.

As with C<run()>, calls to C<txn()> can be nested, although the connection
mode applies only to the outer-most block method call. It's preferable to use
C<dbh()> to fetch the database handle from within the block if your code is
doing lots of non-database processing.

=head3 C<svp>

Executes a code block within the scope of a database savepoint. You can think
of savepoints as a kind of subtransaction. What this means is that you can
nest your savepoints and recover from failures deeper in the nest without
throwing out all changes higher up in the nest. For example:

  $conn->txn( fixup => sub {
      my $dbh = shift;
      $dbh->do('INSERT INTO table1 VALUES (1)');
      eval {
          $conn->svp(sub {
              shift->do('INSERT INTO table1 VALUES (2)');
              die 'OMGWTF?';
          });
      };
      warn "Savepoint failed\n" if $@;
      $dbh->do('INSERT INTO table1 VALUES (3)');
  });

This transaction will insert the values 1 and 3, but not 2.

  $conn->txn( fixup => sub {
      my $dbh = shift;
      $dbh->do('INSERT INTO table1 VALUES (4)');
      $conn->svp(sub {
          shift->do('INSERT INTO table1 VALUES (5)');
      });
  });

This transaction will insert both 4 and 5.

Savepoints are supported by the following RDBMSs:

=over

=item * PostgreSQL 8.0

=item * SQLite 3.6.8

=item * MySQL 5.0.3 (InnoDB)

=item * Oracle

=item * Microsoft SQL Server

=back

Superficially, C<svp()> resembles L<C<run()>|/"run"> and L<C<txn()>|/"txn">,
including its support for the optional L<connection mode|/"Connection Modes">
argument, but it's actually designed to be called from inside a C<txn()>
block. However, C<svp()> will start a transaction for you if it's called
without a transaction in-progress. Each simply redispatches to C<txn()> with
the appropriate connection mode. Thus, this call from outside of a
transaction:

  $conn->svp( ping => sub { ...} );

Is equivalent to:

  $conn->txn( ping => sub {
      $conn->svp( sub { ... } );
  })

But most often you'll want to explicitly use L<C<svp()>|/svp> from within a
transaction block.

=head3 C<with>

  $conn->with('fixup')->txn(sub {
      $_->do('UPDATE users SET active = true' );
  })

Constructs and returns a proxy object that delegates calls to
L<C<run()>|/"run">, L<C<txn()>|/"txn">, and L<C<svp()>|/"svp"> with a default
L<connection mode|/"Connection Modes">. This can be useful if you always use
the same mode and don't want to always have to be passing it as the first
argument to those methods:

  my $proxy = $conn->with('fixup');

  # ... later ...
  $proxy->run( sub { $proxy->dbh->do('SELECT update_bar()') } );

This is mainly designed for use by ORMs and other database tools that need to
require a default connection mode. But others may find it useful as well.
The proxy object offers the following methods:

=over

=item C<conn>

The original DBIx::Connector object.

=item C<mode>

The mode that will be passed to the block execution methods.

=item C<dbh>

Dispatches to the connection's C<dbh()> method.

=item C<run>

Dispatches to the connection's C<run()> method, with the C<mode> preferred
mode.

=item C<txn>

Dispatches to the connection's C<txn()> method, with the C<mode> preferred
mode.

=item C<svp>

Dispatches to the connection's C<svp()> method, with the C<mode> preferred
mode.

=back

=head3 C<connected>

  if ( $conn->connected ) {
      $conn->dbh->do($query);
  }

Returns true if currently connected to the database and false if it's not. You
probably won't need to bother with this method; DBIx::Connector uses it
internally to determine whether or not to create a new connection to the
database before returning a handle from C<dbh()>.

=head3 C<disconnect>

  $conn->disconnect;

Disconnects from the database. If a transaction is in process it will be
rolled back. DBIx::Connector uses this method internally in its C<DESTROY>
method to make sure that things are kept tidy.

=head3 C<driver>

  $conn->driver->begin_work( $conn->dbh );

In order to support all database features in a database-neutral way,
DBIx::Connector provides a number of different database drivers, subclasses of
L<DBIx::Connector::Driver|DBIx::Connector::Driver>, that offer methods to
handle database communications. Although the L<DBI|DBI> provides a standard
interface, for better or for worse, not all of the drivers implement them, and
some have bugs. To avoid those issues, all database communications are handled
by these driver objects.

This can be useful if you want more fine-grained control of your
transactionality. For example, to create your own savepoint within a
transaction, you might do something like this:

  my $driver = $conn->driver;
  $conn->txn( sub {
      my $dbh = shift;
      eval {
          $driver->savepoint($dbh, 'mysavepoint');
          # do stuff ...
          $driver->release('mysavepoint');
      };
      $driver->rollback_to($dbh, 'mysavepoint') if $@;
  });

Most often you should be able to get what you need out of use of
L<C<txn()>|/"txn"> and L<C<svp()>|/"svp">, but sometimes you just need the
finer control. In those cases, take advantage of the driver object to keep
your use of the API universal across database back-ends.

=begin comment

Not sure yet if I want these to be public. I might kill them off.

=head3 C<savepoint>

=head3 C<release>

=head3 C<rollback_to>

Theese are deprecated:

=head3 C<do>

=head3 C<txn_do>

=head3 C<svp_do>

=head3 C<clear_cache>

=end comment

=head1 See Also

=over

=item * L<DBIx::Connector::Driver|DBIx::Connector::Driver>

=item * L<DBI|DBI>

=item * L<DBIx::Class|DBIx::Class>

=item * L<Catalyst::Model::DBI|Catalyst::Model::DBI>

=back

=head1 Support

This module is managed in an open GitHub repository,
L<http://github.com/theory/dbix-connector/tree/>. Feel free to fork and
contribute, or to clone L<git://github.com/theory/dbix-connector.git> and send
patches!

Please file bug reports at L<http://github.com/theory/dbix-connector/issues/>.

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

It is based on documentation, ideas, kibbitzing, and code from:

=over

=item * Tim Bunce <http://tim.bunce.name>

=item * Brandon L. Black <blblack@gmail.com>

=item * Matt S. Trout <mst@shadowcat.co.uk>

=item * Peter Rabbitson <rabbit+dbic@rabbit.us>

=item * Ash Berlin <ash@cpan.org>

=item * Rob Kinyon <rkinyon@cpan.org>

=item * Cory G Watson <gphat@cpan.org>

=item * Anders Nor Berle <berle@cpan.org>

=item * John Siracusa <siracusa@gmail.com>

=item * Alex Pavlovic <alex.pavlovic@taskforce-1.com>

=item * Many other L<DBIx::Class contributors|DBIx::Class/CONTRIBUTORS>

=back

=head1 To Do

=over

=item * Add an C<auto_savepoint> option?

=item * Integrate exception handling in a C<catch()> method?

=back

=head1 Copyright and License

Copyright (c) 2009 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
