package DBIx::Connector;

use 5.006002;
use strict;
use warnings;
use DBI '1.605';
use DBIx::Connector::Driver;

our $VERSION = '0.57';

sub new {
    my $class = shift;
    my @args = @_;
    bless {
        _args      => sub { @args },
        _svp_depth => 0,
        _mode      => 'no_ping',
        _dond      => 1,
    } => $class;
}

sub DESTROY { $_[0]->disconnect if $_[0]->{_dond} }

sub _connect {
    my $self = shift;
    my @args = $self->{_args}->();
    my $dbh = do {
        if ($INC{'Apache/DBI.pm'} && $ENV{MOD_PERL}) {
            local $DBI::connect_via = 'connect'; # Disable Apache::DBI.
            DBI->connect( @args );
        } else {
            DBI->connect( @args );
        }
    } or return undef;

    # Modify default values.
    $dbh->STORE(AutoInactiveDestroy => 1) if DBI->VERSION > 1.613 && (
        @args < 4 || !exists $args[3]->{AutoInactiveDestroy}
    );

    $dbh->STORE(RaiseError => 1) if @args < 4 || (
        !exists $args[3]->{RaiseError} && !exists $args[3]->{HandleError}
    );

    # Where are we?
    $self->{_pid} = $$;
    $self->{_tid} = threads->tid if $INC{'threads.pm'};
    $self->{_dbh} = $dbh;

    # Set up the driver and go!
    return $self->driver->_connect($dbh, @args);
}

sub driver {
    my $self = shift;
    return $self->{driver} if $self->{driver};

    my $driver = do {
        if (my $dbh = $self->{_dbh}) {
            $dbh->{Driver}{Name};
        } else {
            (DBI->parse_dsn( ($self->{_args}->())[0]) )[1];
        }
    };
    $self->{driver} = DBIx::Connector::Driver->new( $driver );
}

sub connect {
    my $self = shift->new(@_);
    $self->{_dond} = 0;
    $self->dbh;
}

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
    return $self->driver->ping($dbh);
}

sub mode {
    my $self = shift;
    return $self->{_mode} unless @_;
    require Carp && Carp::croak(qq{Invalid mode: "$_[0]"})
        unless $_[0] =~ /^(?:fixup|(?:no_)?ping)$/;
    $self->{_mode} = shift;
}

sub disconnect_on_destroy {
    my $self = shift;
    return $self->{_dond} unless @_;
    $self->{_dond} = !!shift;
}

sub in_txn {
    my $dbh = shift->{_dbh} or return;
    return !$dbh->FETCH('AutoCommit');
}

# returns true if there is a database handle and the PID and TID have not
# changed and the handle's Active attribute is true.
sub _seems_connected {
    my $self = shift;
    my $dbh = $self->{_dbh} or return;
    if ( defined $self->{_tid} && $self->{_tid} != threads->tid ) {
        return;
    } elsif ( $self->{_pid} != $$ ) {
        # We've forked, so prevent the parent process handle from touching the
        # DB on DESTROY. Here in the child process, that could really screw
        # things up. This is superfluous when AutoInactiveDestroy is set, but
        # harmless. It's better to be proactive anyway.
        $dbh->STORE(InactiveDestroy => 1);
        return;
    }
    # Use FETCH() to avoid death when called from during global destruction.
    return $dbh->FETCH('Active') ? $dbh : undef;
}

sub disconnect {
    my $self = shift;
    if (my $dbh = $self->{_dbh}) {
        # Some databases need this to stop spewing warnings, according to
        # DBIx::Class::Storage::DBI. Probably Sybase, as the code was added
        # when Sybase ASA and SQLAnywhere support were added to DBIx::Class.
        # If that ever becomes an issue for us, add a _disconnect to the
        # Driver class that does it, don't do it here.
        # $dbh->STORE(CachedKids => {});
        $dbh->disconnect;
        $self->{_dbh} = undef;
    }
    return $self;
}

sub run {
    my $self = shift;
    my $mode = ref $_[0] eq 'CODE' ? $self->{_mode} : shift;
    local $self->{_mode} = $mode;
    return $self->_fixup_run(@_) if $mode eq 'fixup';
    return $self->_run(@_);
  }

sub _run {
    my ($self, $code) = @_;
    my $dbh = $self->{_mode} eq 'ping' ? $self->dbh : $self->_dbh;
    local $self->{_in_run} = 1;
    return _exec( $dbh, $code, wantarray );
}

sub _fixup_run {
    my ($self, $code) = @_;
    my $dbh  = $self->_dbh;

    my $wantarray = wantarray;
    return _exec( $dbh, $code, $wantarray )
        if $self->{_in_run} || !$dbh->FETCH('AutoCommit');

    local $self->{_in_run} = 1;
    my ($err, @ret);
    TRY: {
        local $@;
        @ret = eval { _exec( $dbh, $code, $wantarray ) };
        $err = $@;
    }

    if ($err) {
        die $err if $self->connected;
        # Not connected. Try again.
        return _exec( $self->_connect, $code, $wantarray, @_ );
    }

    return $wantarray ? @ret : $ret[0];
}

sub txn {
    my $self = shift;
    my $mode = ref $_[0] eq 'CODE' ? $self->{_mode} : shift;
    local $self->{_mode} = $mode;
    return $self->_txn_fixup_run(@_) if $mode eq 'fixup';
    return $self->_txn_run(@_);
}

sub _txn_run {
    my ($self, $code) = @_;
    my $driver = $self->driver;
    my $wantarray = wantarray;
    my $dbh = $self->{_mode} eq 'ping' ? $self->dbh : $self->_dbh;

    unless ($dbh->FETCH('AutoCommit')) {
        local $self->{_in_run}  = 1;
        return _exec( $dbh, $code, $wantarray );
    }

    my ($err, @ret);
    TRY: {
        local $@;
        eval {
            local $self->{_in_run}  = 1;
            $driver->begin_work($dbh);
            @ret = _exec( $dbh, $code, $wantarray );
            $driver->commit($dbh);
        };
        $err = $@;
    }

    if ($err) {
        $err = $driver->_rollback($dbh, $err);
        die $err;
    }

    return $wantarray ? @ret : $ret[0];
}

sub _txn_fixup_run {
    my ($self, $code) = @_;
    my $dbh    = $self->_dbh;
    my $driver = $self->driver;

    my $wantarray = wantarray;
    local $self->{_in_run}  = 1;

    return _exec( $dbh, $code, $wantarray ) unless $dbh->FETCH('AutoCommit');

    my ($err, @ret);
    TRY: {
        local $@;
        eval {
            $driver->begin_work($dbh);
            @ret = _exec( $dbh, $code, $wantarray );
            $driver->commit($dbh);
        };
        $err = $@;
    }

    if ($err) {
        if ($self->connected) {
            $err = $driver->_rollback($dbh, $err);
            die $err;
        }

        # Not connected. Try again.
        $dbh = $self->_connect;
        TRY: {
            local $@;
            eval {
                $driver->begin_work($dbh);
                @ret = _exec( $dbh, $code, $wantarray );
                $driver->commit($dbh);
            };
            $err = $@;
        }
        if ($err) {
            $err = $driver->_rollback($dbh, $err);
            die $err;
        }
    }

    return $wantarray ? @ret : $ret[0];
}

sub svp {
    my $self = shift;
    my $dbh  = $self->{_dbh};

    # Gotta have a transaction.
    return $self->txn( @_ ) if !$dbh || $dbh->FETCH('AutoCommit');

    my $mode = ref $_[0] eq 'CODE' ? $self->{_mode} : shift;
    local $self->{_mode} = $mode;
    my $code = shift;

    my ($err, @ret);
    my $wantarray = wantarray;
    my $driver    = $self->driver;
    my $name      = "savepoint_$self->{_svp_depth}";
    ++$self->{_svp_depth};

    TRY: {
        local $@;
        eval {
            $driver->savepoint($dbh, $name);
            @ret = _exec( $dbh, $code, $wantarray );
            $driver->release($dbh, $name);
        };
        $err = $@;
    }
    --$self->{_svp_depth};

    if ($err) {
        # If we died, there is nothing to be done.
        if ($self->connected) {
            $err = $driver->_rollback_and_release($dbh, $name, $err);
        }
        die $err;
    }

    return $wantarray ? @ret : $ret[0];
}

sub _exec {
    my ($dbh, $code, $wantarray) = @_;
    local $_ = $dbh or return;
    # Block prevents exiting via next or last, otherwise no commit/rollback.
    NOEXIT: {
        return $wantarray ? $code->($dbh) : scalar $code->($dbh)
            if defined $wantarray;
        return $code->($dbh);
    }
    return;
}

1;
__END__

=head1 Name

DBIx::Connector - Fast, safe DBI connection and transaction management

=head1 Synopsis

  use DBIx::Connector;

  # Create a connection.
  my $conn = DBIx::Connector->new($dsn, $username, $password, {
      RaiseError => 1,
      AutoCommit => 1,
  });

  # Get the database handle and do something with it.
  my $dbh  = $conn->dbh;
  $dbh->do('INSERT INTO foo (name) VALUES (?)', undef, 'Fred' );

  # Do something with the handle more efficiently.
  $conn->run(fixup => sub {
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

You might be familiar with L<Apache::DBI|Apache::DBI> and with the L<DBI>'s
L<C<connect_cached()>|DBI/connect_cached> constructor. DBIx::Connector serves
a similar need, but does a much better job. How is it different? I'm glad you
asked!

=over

=item * Fork Safety

Like Apache::DBI, but unlike C<connect_cached()>, DBIx::Connector create a new
database connection if a new process has been C<fork>ed. This happens all the
time under L<mod_perl>, in L<POE> applications, and elsewhere. Works best with
DBI 1.614 and higher.

=item * Thread Safety

Unlike Apache::DBI or C<connect_cached()>, DBIx::Connector will create a new
database connection if a new thread has been spawned. As with C<fork>ing,
spawning a new thread can break database connections.

=item * Works Anywhere

Unlike Apache::DBI, DBIx::Connector runs anywhere -- inside of mod_perl or
not. Why limit yourself?

=item * Explicit Interface

DBIx::Connector has an explicit interface. There is none of the magical
action-at-a-distance crap that Apache::DBI is guilty of, and no global
caching. I've personally diagnosed a few issues with Apache::DBI's magic, and
killed it off in two different projects in favor of C<connect_cached()>, only
to be tripped up by other gotchas. No more.

=item * Optimistic Execution

If you use C<run()> and C<txn()>, the database handle will be passed without
first pinging the server. For the 99% or more of the time when the database is
just there, you'll save a ton of overhead without the ping.

=back

DBIx::Connector's other feature is transaction management. Borrowing an
interface from L<DBIx::Class>, DBIx::Connector offers an API that efficiently
handles the scoping of database transactions so that you needn't worry about
managing the transaction yourself. Even better, it offers an API for
savepoints if your database supports them. Within a transaction, you can scope
savepoints to behave like subtransactions, so that you can save some of your
work in a transaction even if part of it fails. See L<C<txn()>|/"txn"> and
L<C<svp()>|/"svp"> for the goods.

=head1 Usage

Unlike L<Apache::DBI> and L<C<connect_cached()>|DBI/connect_cached>,
DBIx::Connector doesn't cache database handles. Rather, for a given
connection, it makes sure that the connection is just there whenever you want
it, to the extent possible. The upshot is that it's safe to create a
connection and then keep it around for as long as you need it, like so:

  my $conn = DBIx::Connector->new(@args);

You can store the connection somewhere in your app where you can easily access
it, and for as long as it remains in scope, it will try its hardest to
maintain a database connection. Even across C<fork>s (especially with DBI
1.614 and higher) and new threads, and even calls to
C<< $conn->dbh->disconnect >>. When you don't need it anymore, let it go out
of scope and the database connection will be closed.

The upshot is that your code is responsible for hanging onto a connection for
as long as it needs it. There is no magical connection caching like in
L<Apache::DBI|Apache::DBI> and L<C<connect_cached()>|DBI/connect_cached>.

=head2 Execution Methods

The real utility of DBIx::Connector comes from the use of the execution
methods, L<C<run()>|/"run">, L<C<txn()>|/"txn">, or L<C<svp()>|/"svp">.
Instead of this:

  $conn->dbh->do($query);

Try this:

  $conn->run(sub { $_->do($query) }); # returns retval from the sub {...}

The difference is that the C<run()> optimistically assumes that an existing
database handle is connected and executes the code reference without pinging
the database. The vast majority of the time, the connection will of course
still be open. You therefore save the overhead of a ping query every time you
use C<run()> (or C<txn()>).

Of course, if a block passed to C<run()> dies because the DBI isn't actually
connected to the database you'd need to catch that failure and try again.
DBIx::Connector provides a way to overcome this issue: connection modes.

=head3 Connection Modes

When calling L<C<run()>|/"run">, L<C<txn()>|/"txn">, or L<C<svp()>|/"svp">,
each executes within the context of a "connection mode." The supported modes
are:

=over

=item * C<ping>

=item * C<fixup>

=item * C<no_ping>

=back

Use them via an optional first argument, like so:

  $conn->run(ping => sub { $_->do($query) });

Or set up a default mode via the C<mode()> accessor:

  $conn->mode('fixup');
  $conn->run(sub { $_->do($query) });

The return value of the block will be returned from the method call in scalar
or array context as appropriate, and the block can use C<wantarray> to
determine the context. Returning the value makes them handy for things like
constructing a statement handle:

  my $sth = $conn->run(fixup => sub {
      my $sth = $_->prepare('SELECT isbn, title, rating FROM books');
      $sth->execute;
      $sth;
  });

In C<ping> mode, C<run()> will ping the database I<before> running the block.
This is similar to what L<Apache::DBI> and the L<DBI>'s
L<C<connect_cached()>|DBI/connect_cached> method do to check the database
connection, and is the safest way to do so. If the ping fails, DBIx::Connector
will attempt to reconnect to the database before executing the block. However,
C<ping> mode does impose the overhead of the C<ping> every time you use it.

In C<fixup> mode, DBIx::Connector executes the block without pinging the
database. But in the event the block throws an exception, if DBIx::Connector
finds that the database handle is no longer connected, it will reconnect to
the database and re-execute the block. Therefore, the code reference should
have B<no side-effects outside of the database,> as double-execution in the
event of a stale database connection could break something:

  my $count;
  $conn->run(fixup => sub { $count++ });
  say $count; # may be 1 or 2

C<fixup> is the most efficient connection mode. If you're confident that the
block will have no deleterious side-effects if run twice, this is the best
option to choose. If you decide that your block is likely to have too many
side-effects to execute more than once, you can simply switch to C<ping> mode.

The default is C<no_ping>, but you likely won't ever use it directly, and
isn't recommended in any event.

Simple, huh? Better still, go for the transaction management in
L<C<txn()>|/"txn"> and the savepoint management in L<C<svp()>|/"svp">. You
won't be sorry, I promise.

=head3 Rollback Exceptions

In the event of a rollback in L<C<txn()>|/"txn"> or L<C<svp()>|/"svp">, if the
rollback itself fails, a DBIx::Connector::TxnRollbackError or
DBIx::Connector::SvpRollbackError exception will be thrown, as appropriate.
These classes, which inherit from DBIx::Connector::RollbackError, stringify to
display both the rollback error and the transaction or savepoint error that
led to the rollback, something like this:

    Transaction aborted: No such table "foo" at foo.pl line 206.
    Transaction rollback failed: Invalid transaction ID at foo.pl line 203.

For finer-grained exception handling, you can access the individual errors via
accessors:

=over

=item C<error>

The transaction or savepoint error.

=item C<rollback_error>

The rollback error.

=back

For example:

  use Try::Tiny;
  try {
      $conn->txn(sub {
          # ...
      });
  } catch {
      if (eval { $_->isa('DBIx::Connector::RollbackError') }) {
          say STDERR 'Transaction aborted: ', $_->error;
          say STDERR 'Rollback failed too: ', $_->rollback_error;
      } else {
          warn "Caught exception: $_";
      }
  };

If a L<C<svp()>|/"svp"> rollback fails and its surrounding L<C<txn()>|/"txn">
rollback I<also> fails, the thrown DBIx::Connetor::TxnRollbackError exception
object will have the savepoint rollback exception, which will be an
DBIx::Connetor::SvpRollbackError exception object in its C<error> attribute:

  use Try::Tiny;
  $conn->txn(sub {
      try {
          $conn->svp(sub { # ... });
      } catch {
          if (eval { $_->isa('DBIx::Connector::RollbackError') }) {
              if (eval { $_->error->isa('DBIx::Connector::SvpRollbackError') }) {
                  say STDERR 'Savepoint aborted: ', $_->error->error;
                  say STDERR 'Its rollback failed too: ', $_->error->rollback_error;
              } else {
                  say STDERR 'Transaction aborted: ', $_->error;
              }
              say STDERR 'Transaction rollback failed too: ', $_->rollback_error;
          } else {
              warn "Caught exception: $_";
          }
      };
  });

But most of the time, you should be fine with the stringified form of the
exception, which will look something like this:

    Transaction aborted: Savepoint aborted: No such table "bar" at foo.pl line 190.
    Savepoint rollback failed: Invalid savepoint name at foo.pl line 161.
    Transaction rollback failed: Invalid transaction identifier at fool.pl line 184.

This allows you to see you original SQL error, as well as the errors for the
savepoint rollback and transaction rollback failures.

=head1 Interface

And now for the nitty-gritty.

=head2 Constructor

=head3 C<new>

  my $conn = DBIx::Connector->new($dsn, $username, $password, {
      RaiseError => 1,
      AutoCommit => 1,
  });

Constructs and returns a DBIx::Connector object. The supported arguments are
exactly the same as those supported by the L<DBI>. Default values for those
parameters vary from the DBI as follows:

=over

=item C<RaiseError>

Defaults to true if unspecified, and if C<HandleError> is unspecified. Use of
the C<RaiseError> attribute, or a C<HandleError> attribute that always throws
exceptions (such as that provided by L<Exception::Class::DBI>), is required
for the exception-handling functionality of L<C<run()>|/"run">,
L<C<txn()>|/"txn">, and L<C<svp()>|/"svp"> to work properly. Their explicit
use is therefor recommended if for proper error handling with these execution
methods.

=item C<AutoInactiveDestroy>

Added in L<DBI> 1.613. Defaults to true if unspecified. This is important for
safe disconnects across forking processes.

=back

In addition, explicitly setting C<AutoCommit> to true is strongly recommended
if you plan to use L<C<txn()>|/"txn"> or L<C<svp()>|/"svp">, as otherwise you
won't get the transactional scoping behavior of those two methods.

If you would like to execute custom logic each time a new connection to the
database is made you can pass a sub as the C<connected> key to the
C<Callbacks> parameter. See L<DBI/Callbacks> for usage and other available
callbacks.

Other attributes may be modified by individual drivers. See the documentation
for the drivers for details:

=over

=item L<DBIx::Connector::Driver::MSSQL>

=item L<DBIx::Connector::Driver::Oracle>

=item L<DBIx::Connector::Driver::Pg>

=item L<DBIx::Connector::Driver::SQLite>

=item L<DBIx::Connector::Driver::mysql>

=item L<DBIx::Connector::Driver::Firebird>

=back

=head2 Class Method

=head3 C<connect>

  my $dbh = DBIx::Connector->connect($dsn, $username, $password, \%attr);

Syntactic sugar for:

  my $dbh = DBIx::Connector->new(@args)->dbh;

Though there's probably not much point in that, as you'll generally want to
hold on to the DBIx::Connector object. Otherwise you'd just use the L<DBI>,
no?

=head2 Instance Methods

=head3 C<dbh>

  my $dbh = $conn->dbh;

Returns the connection's database handle. It will use a an existing handle if
there is one, if the process has not been C<fork>ed or a new thread spawned,
and if the database is pingable. Otherwise, it will instantiate, cache, and
return a new handle.

When called from blocks passed to L<C<run()>|/"run">, L<C<txn()>|/"txn">, and
L<C<svp()>|/"svp">, C<dbh()> assumes that the pingability of the database is
handled by those methods and skips the C<ping()>. Otherwise, it performs all
the same validity checks. The upshot is that it's safe to call C<dbh()> inside
those blocks without the overhead of multiple C<ping>s. Indeed, it's
preferable to do so if you're doing lots of non-database processing in those
blocks.

=head3 C<run>

  $conn->run(ping => sub { $_->do($query) });

Simply executes the block, locally setting C<$_> to and passing in the
database handle. Returns the value returned by the block in scalar or array
context as appropriate (and the block can use C<wantarray> to decide what to
do).

An optional first argument sets the connection mode, overriding that set in
the C<mode()> accessor, and may be one of C<ping>, C<fixup>, or C<no_ping>
(the default). See L</"Connection Modes"> for further explication.

For convenience, you can nest calls to C<run()> (or C<txn()> or C<svp()>),
although the connection mode will be invoked to check the connection (or not)
only in the outer-most block method call.

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
single transaction. If you'd like subtransactions, nest L<C<svp()>|/svp>
calls.

It's preferable to use C<dbh()> to fetch the database handle from within the
block if your code is doing lots of non-database stuff (shame on you!):

  $conn->run(ping => sub {
      parse_gigabytes_of_xml(); # Get this out of the transaction!
      $conn->dbh->do($query);
  });

This is because C<dbh()> will better ensure that the database handle is active
and C<fork>- and thread-safe, although it will never C<ping()> the database
when called from inside a C<run()>, C<txn()> or C<svp()> block.

=head3 C<txn>

  my $sth = $conn->txn(fixup => sub { $_->do($query) });

Starts a transaction, executes the block, locally setting C<$_> to and passing
in the database handle, and commits the transaction. If the block throws an
exception, the transaction will be rolled back and the exception re-thrown.
Returns the value returned by the block in scalar or array context as
appropriate (and the block can use C<wantarray> to decide what to do).

An optional first argument sets the connection mode, overriding that set in
the C<mode()> accessor, and may be one of C<ping>, C<fixup>, or C<no_ping>
(the default). In the case of C<fixup> mode, this means that the transaction
block will be re-executed for a new connection if the database handle is no
longer connected. In such a case, a second exception from the code block will
cause the transaction to be rolled back and the exception re-thrown. See
L</"Connection Modes"> for further explication.

As with C<run()>, calls to C<txn()> can be nested, although the connection
mode will be invoked to check the connection (or not) only in the outer-most
block method call. It's preferable to use C<dbh()> to fetch the database
handle from within the block if your code is doing lots of non-database
processing.

=head3 C<svp>

Executes a code block within the scope of a database savepoint if your
database supports them. Returns the value returned by the block in scalar or
array context as appropriate (and the block can use C<wantarray> to decide
what to do).

You can think of savepoints as a kind of subtransaction. What this means is
that you can nest your savepoints and recover from failures deeper in the nest
without throwing out all changes higher up in the nest. For example:

  $conn->txn(fixup => sub {
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

  $conn->svp(fixup => sub {
      my $dbh = shift;
      $dbh->do('INSERT INTO table1 VALUES (4)');
      $conn->svp(sub {
          shift->do('INSERT INTO table1 VALUES (5)');
      });
  });

This transaction will insert both 4 and 5.

Superficially, C<svp()> resembles L<C<run()>|/"run"> and L<C<txn()>|/"txn">,
including its support for the optional L<connection mode|/"Connection Modes">
argument, but in fact savepoints can only be used within the scope of a
transaction. Thus C<svp()> will start a transaction for you if it's called
without a transaction in-progress. It simply redispatches to C<txn()> with the
appropriate connection mode. Thus, this call from outside of a transaction:

  $conn->svp(ping => sub {
      $conn->svp( sub { ... } );
  });

Is equivalent to:

  $conn->txn(ping => sub {
      $conn->svp( sub { ... } );
  })

Savepoints are supported by the following RDBMSs:

=over

=item * PostgreSQL 8.0

=item * SQLite 3.6.8

=item * MySQL 5.0.3 (InnoDB)

=item * Oracle

=item * Microsoft SQL Server

=item * Firebird 1.5

=back

For all other RDBMSs, C<svp()> works just like C<txn()>: savepoints will be
ignored and the outer-most transaction will be the only transaction. This
tends to degrade well for non-savepoint-supporting databases, doing the right
thing in most cases.

=head3 C<mode>

  my $mode = $conn->mode;
  $conn->mode('fixup');
  $conn->txn(sub { ... }); # uses fixup mode.
  $conn->mode($mode);

Gets and sets the L<connection mode|/"Connection Modes"> attribute, which is
used by C<run()>, C<txn()>, and C<svp()> if no mode is passed to them.
Defaults to "no_ping". Note that inside a block passed to C<run()>, C<txn()>,
or C<svp()>, the mode attribute will be set to the optional first parameter:

  $conn->mode('ping');
  $conn->txn(fixup => sub {
      say $conn->mode; # Outputs "fixup"
  });
  say $conn->mode; # Outputs "ping"

In this way, you can reliably tell in what mode the code block is executing.

=head3 C<connected>

  if ( $conn->connected ) {
      $conn->dbh->do($query);
  }

Returns true if currently connected to the database and false if it's not. You
probably won't need to bother with this method; DBIx::Connector uses it
internally to determine whether or not to create a new connection to the
database before returning a handle from C<dbh()>.

=head3 C<in_txn>

  if ( $conn->in_txn ) {
     say 'Transacting!';
  }

Returns true if the connection is in a transaction. For example, inside a
C<txn()> block it would return true. It will also work if you use the DBI API
to manage transactions (i.e., C<begin_work()> or C<AutoCommit>.

Essentially, this is just sugar for:

  $con->run( no_ping => sub { !$_->{AutoCommit} } );

But without the overhead of the code reference or connection checking.

=head3 C<disconnect_on_destroy>

  $conn->disconnect_on_destroy(0);

By default, DBIx::Connector calls C<< $dbh->disconnect >> when it goes out of
scope and is garbage-collected by the system (that is, in its C<DESTROY()>
method). Usually this is what you want, but in some cases it might not be. For
example, you might have a module that uses DBIx::Connector internally, but
then makes the database handle available to callers, even after the
DBIx::Connector object goes out of scope. In such a case, you don't want the
database handle to be disconnected when the DBIx::Connector goes out of scope.
So pass a false value to C<disconnect_on_destroy> to prevent the disconnect.
An example:

  sub database_handle {
       my $conn = DBIx::Connector->new(@_);
       $conn->run(sub {
           # Do stuff here.
       });
       $conn->disconnect_on_destroy(0);
       return $conn->dbh;
  }

Of course, if you don't need to do any work with the database handle before
returning it to your caller, you can just use C<connect()>:

  sub database_handle {
      DBIx::Connector->connect(@_);
  }

=head3 C<disconnect>

  $conn->disconnect;

Disconnects from the database. Unless C<disconnect_on_destroy()> has been
passed a false value, DBIx::Connector uses this method internally in its
C<DESTROY> method to make sure that things are kept tidy.

=head3 C<driver>

  $conn->driver->begin_work( $conn->dbh );

In order to support all database features in a database-neutral way,
DBIx::Connector provides a number of different database drivers, subclasses of
L<DBIx::Connector::Driver>, that offer methods to handle database
communications. Although the L<DBI> provides a standard interface, for better
or for worse, not all of the drivers implement them, and some have bugs. To
avoid those issues, all database communications are handled by these driver
objects.

This can be useful if you want more fine-grained control of your
transactionality. For example, to create your own savepoint within a
transaction, you might do something like this:

  use Try::Tiny;
  my $driver = $conn->driver;
  $conn->txn(sub {
      my $dbh = shift;
      try {
          $driver->savepoint($dbh, 'mysavepoint');
          # do stuff ...
          $driver->release('mysavepoint');
      } catch {
          $driver->rollback_to($dbh, 'mysavepoint');
      };
  });

Most often you should be able to get what you need out of L<C<txn()>|/"txn">
and L<C<svp()>|/"svp">, but sometimes you just need the finer control. In
those cases, take advantage of the driver object to keep your use of the API
universal across database back-ends.

=head1 See Also

=over

=item * L<DBIx::Connector::Driver>

=item * L<DBI>

=item * L<DBIx::Class>

=item * L<Catalyst::Model::DBI>

=back

=head1 Support

This module is managed in an open
L<GitHub repository|http://github.com/theory/dbix-connector/>. Feel free to
fork and contribute, or to clone L<git://github.com/theory/dbix-connector.git>
and send patches!

Found a bug? Please L<post|http://github.com/theory/dbix-connector/issues> or
L<email|mailto:bug-dbix-connector@rt.cpan.org> a report!

=head1 Authors

This module was written and is maintained by:

=over

=item *

David E. Wheeler <david@kineticode.com>

=back

It is based on documentation, ideas, kibbitzing, and code from:

=over

=item * Tim Bunce <http://tim.bunce.name>

=item * Brandon L. Black <blblack@gmail.com>

=item * Matt S. Trout <mst@shadowcat.co.uk>

=item * Peter Rabbitson <ribasushi@cpan.org>

=item * Ash Berlin <ash@cpan.org>

=item * Rob Kinyon <rkinyon@cpan.org>

=item * Cory G Watson <gphat@cpan.org>

=item * Anders Nor Berle <berle@cpan.org>

=item * John Siracusa <siracusa@gmail.com>

=item * Alex Pavlovic <alex.pavlovic@taskforce-1.com>

=item * Many other L<DBIx::Class contributors|DBIx::Class/CONTRIBUTORS>

=back

=head1 Copyright and License

Copyright (c) 2009-2013 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
