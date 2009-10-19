package DBIx::Connector;

use 5.6.2;
use strict;
use warnings;
use DBI '1.605';
use DBIx::Connector::Driver;

our $VERSION = '0.13';

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

# $conn->run( fixup   => sub { } );
# $conn->txn( ping    => sub { });
# $conn->svp( no_ping => sub { });

# my $proxy = $conn->with('fixup');
# $proxy->run( sub { } );

# $conn->run( txn       => sub { } );
# $conn->run( fixup     => sub { } );
# $conn->run( svp       => sub { } );
# $conn->run( no_ping   => sub { } );
# $conn->run( svp       => sub { } );

# $conn->run( txn => fixup => sub { } );
# $conn->run( svp => fixup => sub { } );
# $conn->run( txn => no_ping => sub { } );
# $conn->run( svp => no_ping => sub { } );

# $conn->with('fixup')->run( sub { });

# $conn->run( sub { } );
# $conn->run( fixup => sub { } );
# $conn->run( ping  => sub { } );

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
    shift->_svp_fixup_run(@_);
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
database handle if a new thread has been spawned. As with C<fork>ing, spawning
a new thread can break database connections.

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

If you use the C<fixup> mode of the C<run()> method, the database handle will
be passed without first pinging the server. For the 99% or more of the time
when the database is just there, you'll save a ton of overhead without the
ping. DBIx::Connector will only ping the server and reconnected if a query
fails.

=back

The second function of DBIx::Connector is transaction management. Borrowing
from L<DBIx::Class|DBIx::Class>, DBIx::Connector offers an interface that
efficiently handles the scoping of database transactions so that you needn't
worry about managing the transaction yourself. Even better, it offers an
interface for savepoints if your database supports them. Within a transaction,
you can scope savepoints to behave like subtransactions, so that you can save
some of your work in a transaction even if some of it fails. See
L<C<run()>|/"run"> for the goods.

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

=head3 C<run>

=head3 C<txn>

=head3 C<svp>

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
