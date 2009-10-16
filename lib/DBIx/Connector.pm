package DBIx::Connector;

use 5.6.2;
use strict;
use warnings;
use DBI '1.605';
use DBIx::Connector::Driver;
use constant MP  => !!$ENV{MOD_PERL};
use constant MP2 => $ENV{MOD_PERL_API_VERSION} &&
    $ENV{MOD_PERL_API_VERSION} == 2;

our $VERSION = '0.13';

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

        return $CACHE{$key} if $CACHE{$key};

        my $self = bless {
            _args      => $args,
            _key       => $key,
            _svp_depth => 0,
        } => $class;

        if (MP) {
            # Don't cache connections created during Apache initialization.
            if (MP2) {
                require Apache2::ServerUtil;
                return $self if Apache2::ServerUtil::restart_count() == 1;
            }
            return $self if $Apache::ServerStarting
                        and $Apache::ServerStarting == 1;
        }

        return $CACHE{$key} = $self;
    }

    sub clear_cache {
        %CACHE = ();
        shift;
    }

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
    # return $dbh if MP && $dbh->{Active};
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
    $self->_run( $self->_dbh, @_ );
}

sub ping_run {
    my $self = shift;
    $self->_run( $self->dbh, @_ );
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

sub fixup_run {
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

sub txn_run {
    my $self = shift;
    $self->_txn_run( $self->_dbh, @_ );
}

sub txn_ping_run {
    my $self = shift;
    $self->_txn_run( $self->dbh, @_ );
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

sub txn_fixup_run {
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

sub svp_run {
    my $self = shift;
    $self->_svp_run( txn_run => @_);
}

sub svp_ping_run {
    my $self = shift;
    $self->_svp_run( txn_ping_run => @_);
}

sub svp_fixup_run {
    my $self = shift;
    $self->_svp_run( txn_fixup_run => @_);
}

sub _svp_run {
    my $self = shift;
    my $meth = shift;
    my $code = shift;
    my $dbh  = $self->{_dbh};

    # Gotta have a transaction.
    if (!$dbh || $dbh->{AutoCommit}) {
        my @args = @_;
        return $self->$meth( sub { $self->svp_run($code, @args) } );
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

# Deprecated methods.
sub do {
    require Carp;
    Carp::cluck('DBIx::Connctor::do() is deprecated; use fixup_run() instead');
    shift->fixup_run(@_);
}

sub txn_do {
    require Carp;
    Carp::cluck('txn_do() is deprecated; use txn_fixup_run() instead');
    shift->txn_fixup_run(@_);
}

sub svp_do {
    require Carp;
    Carp::cluck('svp_do() is deprecated; use svp_run() instead');
    shift->svp_fixup_run(@_);
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

# XXX Consider adding adverbial method to decorate a `run()` call?
# $conn->with(qw(ping fixup))->txn_run(sub {});
# $conn->with('ping')->txn_run(sub {});
# $conn->with('fixup')->txn_run(sub {});

# $conn-run_with(qw(txn ping))->(sub {} );
# $conn-run_with(qw(txn ping fixup))->(sub {} );
# $conn-run_with(qw(ping))->(sub {} );
# $conn-run_with(qw(fixup))->(sub {} );
# $conn-run_with('txn')->(sub {} );
# $conn-run_with('svp')->(sub {} );

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

  # Fetch a cached DBI handle.
  my $dbh = DBIx::Connector->connect($dsn, $username, $password, \%attr );

  # Fetch a cached connection.
  my $conn = DBIx::Connector->new($dsn, $username, $password, \%attr );

  # Get the handle and do something with it.
  my $dbh  = $conn->dbh;
  $dbh->run('INSERT INTO foo (name) VALUES (?)', undef, 'Fred' );

  # Do something with the handle more efficiently.
  $conn->fixup_run(sub {
      $_->do('INSERT INTO foo (name) VALUES (?)', undef, 'Fred' );
  });

=head1 Description

DBIx::Connector provides a simple interface for fast and safe DBI connection
and transaction management. Connecting to a database can be expensive; you
don't want your application to re-connect every time you need to run a query.
The efficient thing to do is to cache database handles and then just fetch
them from the cache as needed in order to minimize that overhead. Let
DBIx::Connector do that for you.

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
database handle if a new thread has been spawned. Like C<fork>ing, spawning a
new thread can break database connections.

=item * Works Anywhere

Like Apache::DBI, DBIx::Connector doesn't cache its objects during mod_perl
startup, but unlike Apache::DBI, it runs anywhere -- inside of mod_perl or
not. Why limit yourself?

=item * Explicit Interface

DBIx::Connector has an explicit interface. There is none of the magical
action-at-a-distance crap that Apache::DBI is guilty of. I've personally
diagnosed a few issues with Apache::DBI's magic, and killed it off in two
different applications in favor of C<connect_cached()>. No more.

=item * Optimistic Execution

If you use the C<fixup_run()> or C<txn_fixup_run()> methods, the database
handle will be passed without first pinging the server. For the 99% or more of
the time when the database is just there, you'll save a ton of overhead
without the ping. DBIx::Connector will only connect to the server if a query
fails.

=back

The second function of DBIx::Connector is transaction management. Borrowing
from L<DBIx::Class|DBIx::Class>, DBIx::Connector offers an interface that
efficiently handles the scoping of database transactions so that you needn't
worry about managing the transaction yourself. Even better, it offers an
interface for savepoints if your database supports them. Within a transaction,
you can scope savepoints to behave like subtransactions, so that you can save
some of your work in a transaction even if some of it fails. See
L<C<txn_fixup_run()>|/"txn_fixup_run"> and L<C<svp_run()>|/"svp_run"> for the
goods.

=head2 Usage

If you're used to L<Apache::DBI|Apache::DBI> or
L<C<connect_cached()>|DBI/connect_cached>, the simplest thing to do is to use
the C<connect()> class method. Just change your calls from:

  my $dbh = DBI->connect(@args);

Or:

  my $dbh = DBI->connect_cached(@args);

To:

  my $dbh = DBIx::Connector->connect(@args);

DBIx::Connector will return a cached database handle whenever possible,
making sure that it's C<fork>- and thread-safe and connected to the database.
If you do nothing else, making this switch will save you some headaches.

But the real utility of DBIx::Connector comes from its C<fixup_run()>, and
C<txn_fixup_run()> methods. Instead of this:

  my $dbh = DBIx::Connector->connect(@args);
  $dbh->do($query);

Try this:

  my $conn = DBIx::Connector->new(@args);
  $conn->fixup_run(sub { $_->do($query) });

The difference is that if it finds a cached database handle, C<fixup_run()>
optimistically assumes that it's connected and executes the code reference
without pinging the database. The vast majority of the time, the connection
will of course still be open. You therefore save the overhead of a ping query
every time you use C<fixup_run()>.

It's only if the code reference dies that C<fixup_run()> will ping the
database. If the ping fails (because the database was restarted, for example),
I<then> C<fixup_run()> will try to create a new database handle and execute
the code reference again.

If you decide that your code block is likely to have too many side-effects to
execute more than once, you can simply switch to C<ping_run()>. These methods
only execute once, but will ping the database before executing the code block.

Simple, huh? Better still, go for the transaction management in
L<C<txn_fixup_run()>|/"txn_fixup_run"> or L<C<txn_ping_run()>|/"txn_ping_run">
and the savepoint management in L<C<svp_run()>|/"svp_run">. You won't be
sorry, I promise.

=head1 Interface

And now for the nitty-gritty.

=head2 Constructor

=head3 C<new>

  my $conn = DBIx::Connector->new($dsn, $username, $password, \%attr);

Returns a cached DBIx::Connector object. The supported arguments are exactly
the same as those supported by the L<DBI|DBI>, and these also determine the
connection object to be returned. If C<new()> (or C<connect()>) has been
called before with exactly the same arguments (including the contents of the
attributes hash reference), then the same connection object will be returned.
Otherwise, a new object will be instantiated, cached, and returned.

And now, a cautionary note lifted from the DBI documentation: Caching
connections can be useful in some applications, but it can also cause
problems, such as too many connections, and so should be used with care. In
particular, avoid changing the attributes of a database handle returned from
L<C<dbh()>|/"dbh"> because it will effect other code that may be using the
same connection.

As with the L<DBI|DBI>'s L<C<connect_cached()>|DBI/connect_cached> method,
where multiple separate parts of a program are using DBIx::Connector to
connect to the same database with the same (initial) attributes, it is a good
idea to add a private attribute to the the C<new()> call to effectively limit
the scope of the caching. For example:

  DBIx::Connector->new(..., { private_foo_key => "Bar", ... });

Connections returned from that call will only be returned by other calls to
C<new()> (or to L<C<connect()>|/"connect">) elsewhere in the code if those
other calls pass in the same attribute values, including the private one. (The
use of "private_foo_key" here is an example; you can use any attribute name
with a "private_" prefix.)

Taking that one step further, you can limit a particular connection to one
place in the code by setting the private attribute to a unique value for that
place:

  DBIx::Connector->new(..., { private_foo_key => __FILE__.__LINE__, ... });

By using a private attribute you still get connection caching for the
individual calls to C<new()> but, by making separate database connections for
separate parts of the code, the database handles are isolated from any
attribute changes made to other handles.

=head2 Class Method

=head3 C<connect>

  my $dbh = DBIx::Connector->connect($dsn, $username, $password, \%attr);

Returns a cached database handle similar to what you would expect from the
DBI's L<C<connect_cached()>|DBI/connect_cached> method -- except that it
ensures that the handle is C<fork>- and thread-safe.

Otherwise, like C<connect_cached()>, it ensures that the handle is connected
to the database before returning the handle. If it's not, it will instantiate,
cache, and return a new handle.

This method is provided as syntactic sugar for:

  my $dbh = DBIx::Connector->new(@args)->dbh;

So be sure to carefully read the documentation for C<new()> as well.
DBIx::Connector provides this method for those who just want to switch from
Apache::DBI or C<connect_cached()>. Really you want more, though. Trust me.
Read on!

=head3 C<clear_cache>

  DBIx::Connector->clear_cache;

Clears the cache of all connection objects. Could be useful in certain server
settings where a parent process has connected to the database and then forked
off children and no longer needs to be connected to the database itself. (FYI
mod_perl users: DBIx::Connector doesn't cache its objects during mod_perl
startup, so you don't need to clear the cache manually.)

=head2 Instance Methods

=head3 C<dbh>

  my $dbh = $conn->dbh;

Returns the connection's database handle. It will use a cached copy of the
handle if there is one, the process has not been C<fork>ed or a new thread
spawned, and if the database is pingable. Otherwise, it will instantiate,
cache, and return a new handle.

Inside blocks passed the various L<C<*run()>|/"Database Execution Methods">
methods, C<dbh()> assumes that the pingability of the database is handled by
those methods and skips the C<ping()>. Otherwise, it performs all the same
validity checks. The upshot is that it's safe to call C<dbh()> inside those
blocks without the overhead of multiple C<ping>s.

=head3 C<connected>

  if ( $conn->connected ) {
      $conn->dbh->do($query);
  }

Returns true if the database handle is connected to the database and false if
it's not. You probably won't need to bother with this method; DBIx::Connector
uses it internally to determine whether or not to create a new connection to
the database before returning a handle from C<dbh()>.

=head3 C<disconnect>

  $conn->disconnect;

Disconnects from the database. If a transaction is in process it will be
rolled back. DBIx::Connector uses this method internally in its C<DESTROY>
method to make sure that things are kept tidy.

=head3 C<driver>

  $conn->driver->begin_work( $conn->dbh );

In order to support all database features in a database-neutral way,
DBIx::Connector provides a number of different database drivers, subclasses of
<LDBIx::Connector::Driver|DBIx::Connector::Driver>, that offer methods to
handle database communications. Although the L<DBI|DBI> provides a standard
interface, for better or for worse, not all of the drivers implement them, and
some have bugs. To avoid those issues, all database communications are handled
by these driver objects.

This can be useful if you want to do some more fine-grained control of your
transactionality. For example, to create your own savepoint within a
transaction, you might do something like this:

  my $driver = $conn->driver;
  $conn->fixup_run_txn( sub {
      my $dbh = shift;
      eval {
          $driver->savepoint($dbh, 'mysavepoint');
          # do stuff ...
          $driver->release('mysavepoint');
      };
      $driver->rollback_to($dbh, 'mysavepoint') if $@;
  });

Most often you should be able to get what you need out of use of
C<txn_fixup_run()> and C<svp_run()>, but sometimes you just need the finer
control. In those cases, take advantage of the driver object to keep your use
of the API universal across database back-ends.

=begin comment

Not sure yet if I want these to be public. I might kill them off.

=head3 C<savepoint>

=head3 C<release>

=head3 C<rollback_to>

Theese are deprecated:

=head3 C<do>

=head3 C<txn_do>

=head3 C<svp_do>

=end comment

=head2 Database Execution Methods

These methods provide a convenient interface for running blocks of code
(anonymous subroutines) that work with the database. Each executes a code
block, setting C<$_> to and passing in the database handle. It's an easy
way to group together related database work in a single expression.

The basic structure of each is:

  my $result = $conn->run(sub { $_->do($query) });

That is, the database handle is stored in C<$_> for the duration of the call,
and also passed as the first argument to the block. Any other arguments passed
are passed as extra arguments to the block:

  my @res = $conn->run(sub {
      my ($dbh, @args) = @_;
      $dbh->selectrow_array(@args);
  }, $query, $sql, undef, $value);

For convenience, you can nest calls to any C<*run()> methods:

  $conn->txn_run(sub {
      my $dbh = shift;
      $dbh->do($_) for @queries;
      $conn->run(sub {
          $_->do($expensive_query);
          $conn->txn_run(sub {
              $_->do($another_expensive_query);
          });
      });
  });

All code executed inside the top-level call to a C<txn_*run()> method will be
executed in a single transaction. If you'd like subtransactions, see
L<C<svp_run()>|/svp_run>.

It's preferable to fetch the database handle from within the block using
C<dbh()> if your code is doing lots of non-database stuff (shame on you!):

  $conn->txn_run(sub {
      parse_gigabytes_of_xml(); # Get this out of the transaction!
      $conn->dbh->do($query);
  });

The reason for this is the C<dbh()> will better ensure that the database
handle is active and C<fork>- and thread-safe, although it will never
C<ping()> the database when called from inside a C<*run()> block.

The reason for the different methods is that each does something different
with cached database handles. They all check that a cached database handle is
active and C<fork>- and thread-safe, and reconnect if it's not. But the action
taken to ensure that the handle is still connected to the database, which is
an expensive operation, varies.

=head3 C<run>

  my $sth = $conn->run(sub { $_->prepare($query) });

Simply executes the block, setting C<$_> to and passing in the database
handle. See L</"Database Execution Methods"> for a usage overview.

=head3 C<ping_run>

  my $sth = $conn->ping_run(sub { $_->prepare($query) });

Calls C<ping()> on the database handle before calling the block. If the ping
fails, it will re-connect to the database before calling the block. This is
not unlike using the handle returned by C<dbh()>. See L</"Database Execution
Methods"> for a usage overview.

=head3 C<fixup_run>

  my $sth = $conn->fixup_run(sub { $_->prepare($query) });

Like C<run()> it executes the block without pinging the database.
However, in the event the code throws an exception, C<fixup_run()> will reconnect to
the database and re-execute the code reference if the database handle is no
longer connected. Therefore, the code reference should have B<no side-effects
outside of the database,> as double-execution in the event of a stale database
connection could break something:

  my $count;
  $conn->fixup_run(sub { $count++ });
  say $count; # may be 1 or 2

See L</"Database Execution Methods"> for a usage overview.

=head2 Transaction Execution Methods

Like the L<execution methods|/"Database Execution Methods">, these methods
executes a code block, setting C<$_> to and passing in the database handle.
The difference is that they wrap the execution of the block in a transaction.

If you've manually started a transaction -- either by instantiating the
DBIx::Connector object with C<< AutoCommit => 0 >> or by calling
C<begin_work()> on the database handle, execution will take place inside
I<that> transaction, and you will need to handle the necessary commit or
rollback yourself.

Assuming that C<txn_run()> started the transaction, in the event of a failure
the transaction will be rolled back. In the event of success, it will of
course be committed. For the rest, see L</"Database Execution Methods">.

=head3 C<txn_run>

  my $sth = $conn->txn_run(sub { $_->do($query) });

Starts a transaction, executes the block block, setting C<$_> to and passing
in the database handle, and commits the transaction. If the block throws an
exception, the transaction will be rolled back and the exception re-thrown.
See L</"Transaction Execution Methods"> for a usage overview.

=head3 C<txn_ping_run>

 $conn->txn_ping_run(sub { $_->do($_) for @queries });

Calls C<ping()> on the database handle before starting a transaction and
calling the block. If the ping fails, it will re-connect to the database
before calling the block. If the block dies, the transaction will be rolled
back and the exception propagated to the caller. Otherwise, the transaction
will be committed. See L</"Transaction Execution Methods"> for a usage
overview.

=head3 C<txn_fixup_run>

 $conn->txn_ping_run(sub { $_->do($_) for @queries });

Starts a transaction, executes the block, and commits the transaction without
pinging the database. In the event the code throws an exception,
C<txn_fixup_run()> will reconnect to the database and transactionally
re-execute the block if the database handle is no longer connected. Therefore,
the code reference should have B<no side-effects outside of the database,> as
double-execution in the event of a stale database connection could break
something:

  my $count;
  $conn->txn_fixup_run(sub { $count++ });
  say $count; # may be 1 or 2

See L</"Transaction Execution Methods"> for a usage overview.

=head2 Savepoint Methods

These methods execute a code block within the scope of a database savepoint.
You can think of savepoints as a kind of subtransaction. What this means is
that you can nest your savepoints and recover from failures deeper in the nest
without throwing out all changes higher up in the nest. For example:

  $conn->txn_fixup_run(sub {
      my $dbh = shift;
      $dbh->do('INSERT INTO table1 VALUES (1)');
      eval {
          $conn->svp_run(sub {
              shift->do('INSERT INTO table1 VALUES (2)');
              die 'OMGWTF?';
          });
      };
      warn "Savepoint failed\n" if $@;
      $dbh->do('INSERT INTO table1 VALUES (3)');
  });

This transaction will insert the values 1 and 3, but not 2.

  $conn->txn_fixup_run(sub {
      my $dbh = shift;
      $dbh->do('INSERT INTO table1 VALUES (4)');
      $conn->svp_run(sub {
          shift->do('INSERT INTO table1 VALUES (5)');
      });
  });

This transaction will insert both 4 and 5.

Savepoints are currently supported by the following RDBMSs:

=over

=item * PostgreSQL 8.0

=item * SQLite 3.6.8

=item * MySQL 5.0.3 (InnoDB)

=item * Oracle

=item * Microsoft SQL Server

=back

Superficially, these methods resemble the L<C<txn*run()>|/Transaction
Execution Methods> methods but are actually designed to be called from inside
a C<txn*run()> block. They will, however, start a transaction for you if it's
called without a transaction in-progress. Each simply redispatches to the
C<txn*run()> method to which it corresponds. But most often you'll just want
to use L<C<svp_run()>|/svp_run> from within a transaction block.

=head3 C<svp_run>

  $conn->txn_fixup_run(sub {
      $conn->svp_run(sub {
          my $dbh = shift;
          $dbh->do($expensive_query);
          $conn->svp_run(sub {
              shift->do($other_query);
          });
      });
  });

Executes code within the context of a savepoint if your database supports it.
If no transaction is in progress, C<svp_run()> will start one by calling
L<C<txn_run()>|/txn_run>.

=head3 C<svp_ping_run>

Executes code within the context of a savepoint if your database supports it.
If no transaction is in progress, C<svp_run()> will start one by calling
L<C<txn_ping_run()>|/txn_ping_run>.

=head3 C<svp_fixup_run>

Executes code within the context of a savepoint if your database supports it.
If no transaction is in progress, C<svp_run()> will start one by calling
L<C<txn_fixup_run()>|/txn_fixup_run>.

=head1 Best Practices

So you've noticed that there are three types of database execution methods,
simple, transactional, and savepoint, and that each type has three separate
methods that handle database connectivity in different ways: simple, ping, and
fixup. So which do you use? Let's look at types first.

=head2 What Transactionality?

The simple execution methods, L<C<run()>|/run>, L<C<ping_run()>|/ping_run>,
and L<C<fixup_run()>|/fixup_run>, are used for for simple database
communications where you don't care about transactions. Perhaps you just have
one query to execute, or you execute a database function that does all of its
work in an implicit transaction. Or maybe you're not updating data, but simply
running C<SELECT> statements. For these situations, the simple execution
methods are the obvious choice.

And if it happens that you have an application that starts a transaction at
some high-level scope, such as for the duration of an HTTP request, these
methods are likely safe to run, as they will be executed within the scope of
that transaction with no side-effects.

The transactional execution methods, L<C<txn_run()>|/txn_run>,
L<C<ping_txn_run()>|/ping_txn_run>, and L<C<fixup_txn_run()>|/fixup_txn_run>,
are an obvious choice when you need to ensure that all of your is committed to
the database atomically. If, however, you need to do a lot of processing
that's not database related, it's best to do it outside of a transaction, and
just do the database-access work inside the transaction block.

Like the simple execution methods, if you run transactions at a high level in
your application, like for the duration of an HTTP request, it's safe to use
the transaction execution methods -- in such a case, they'll work just like
the simple execution methods. So it might be useful to use the transaction
execution methods to scope logical groups of work, even if there is a
higher-level transaction running, as then they'll be there to make the
transactional scope if you ever decide to eliminate the higher-level
transaction.

The savepoint execution methods L<C<svp_run()>|/svp_run>,
L<C<ping_svp_run()>|/ping_svp_run>, and L<C<fixup_svp_run()>|/fixup_svp_run>,
are designed specifically to break up a transaction into subtransactions. They
are thus best used only if you need to make sure that a part of a transaction
is committed, even if another part fails. Unlike the simple and transaction
execution methods, they will I<always> run as a savepoint-scoped block. So be
sure that a subtransaction is what you really want.

=head2 What Connectivity?

So you've decided what kind of transactionality you need to use, and at what
scope. Now the question is which connectivity should you use?

The simple connection options, L<C<run()>|/run>, L<C<txn_run()>|/txn_run>, and
L<C<svp_run()>|/svp_run>, never properly check database connectivity. They do
validate that the process hasn't C<fork>ed or a new thread been spawned, and
check that the database handle is active, but they never ping the database. In
general you won't want to use C<run()> or C<txn_run()> at all. They're fine to
run inside the block of C<*ping_run()> or C<*fixup_run()> method, but best not
to be called on their own, since if they fail due to a simple connectivity
failure, your work will be lost.

L<C<svp_run()>|/svp_run>, on the other hand, you'll generally want to be your
default choice for scoping execution to a savepoint, as long as you run it
within the scope of a C<*ping_run()> or C<*fixup_run()> block.

The ping methods, L<C<ping_run()>|/ping_run>,
L<C<txn_ping_run()>|/txn_ping_run>, and L<C<svp_ping_run()>|/svp_ping_run>, are
the safest methods to use. When called outside the scope of another C<*run()>
method block, they will always ping the database before running the block.
When called from within a C<*run()> block, they behave just like the simple
methods, leaving the handle check to those methods. So don't call them from
within the simple connectivity methods, which don't ping the database either!

The run methods, L<C<fixup_run()>|/fixup_run>,
L<C<txn_fixup_run()>|/txn_fixup_run>, and
L<C<svp_fixup_run()>|/svp_fixup_run>, are the most efficient methods to use.
If you're confident that the code block passed will have no deleterious
side-effects if it happens to be run twice, this is the best option to choose.
If it's not okay for the block to be executed twice, prefer the ping methods.

=head2 Upshot

In short, my recommendations are:

=over

=item *

Use transactions where appropriate.

=item *

If you need to run code that cannot execute twice, use the ping methods.

=item *

If your database execution code only touches the database, prefer the fixup methods.

=item *

Use C<svp_run()> to scope savepoints within a call to C<txn_ping_run()> or
C<txn_fixup_run()>.

=back

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
