#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 131;
#use Test::More 'no_plan';
use Test::MockModule;

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connector';
    use_ok $CLASS or die;
}

# Try the basics.
ok my $conn = $CLASS->new, 'Create new connector object';
isa_ok $conn, $CLASS;
ok !$conn->connected, 'Should not be connected';
ok !$conn->in_txn, 'Should not be in txn';
eval { $conn->dbh };
ok $@, 'Should get error for no connector args';
ok $conn->disconnect, 'Disconnect should not complain';

# Test mode accessor.
is $conn->mode, 'no_ping', 'Mode should be "no_ping"';
ok $conn->mode('fixup'), 'Set mode to "fixup"';
is $conn->mode, 'fixup', 'Mode should now be "fixup"';
ok $conn->mode('ping'), 'Set mode to "ping"';
is $conn->mode, 'ping', 'Mode should now be "ping"';
eval { $conn->mode('foo') };
ok my $e = $@, 'Should get an error for invalid mode';
like $e, qr/Invalid mode: "foo"/, 'It should be the expected error';

# Test disconnect_on_destroy accessor.
ok $conn->disconnect_on_destroy, 'Should disconnect on destroy by default';
ok !$conn->disconnect_on_destroy(0), 'Set disconnect on destroy to false';
ok !$conn->disconnect_on_destroy, 'Should no longer disconnect on destroy';
ok $conn->disconnect_on_destroy(12), 'Set disconnect on destroy to true';
ok $conn->disconnect_on_destroy, 'Should disconnect on destroy again';

# Set some connect args.
ok $conn = $CLASS->new( 'whatever', 'you', 'want' ),
    'Construct object with bad args';
eval { $conn->connect };
ok $@, 'Should get error for bad args';

# Connect f'real.
ok $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ),
    'Construct connector with good args';
isa_ok $conn, $CLASS;
ok !$conn->connected, 'Should not yet be connected';
is $conn->{_tid}, undef, 'tid should be undef';
is $conn->{_pid}, undef, 'pid should be undef';

# dbh.
ok my $dbh = $conn->dbh, 'Connect to the database';
isa_ok $dbh, 'DBI::db';
is $conn->{_dbh}, $dbh, 'The _dbh attribute should be set';
is $conn->{_tid}, undef, 'tid should still be undef';
is $conn->{_pid}, $$, 'pid should be set';
ok !$conn->in_txn, 'We should not be in a txn';
ok $conn->connected, 'We should be connected';

# Disconnect.
my $mock = Test::MockModule->new( ref $dbh, no_auto => 1 );
my ($rollback, $disconnect, $ping) = (0, 0, 0);
$mock->mock( disconnect => sub { ++$disconnect } );
$mock->mock( ping       => sub { ++$ping } );
is $ping, 0, 'No pings yet';
ok $conn->disconnect, 'disconnect should execute without error';
is $ping, 0, 'disconnect should not have pinged';
ok $disconnect, 'It should have called disconnect on the database handle';
ok !$rollback,  'But not rollback';
is $conn->{_dbh}, undef, 'The _dbh accessor should now return undef';

# Start a transaction.
ok $dbh = $conn->dbh, 'Connect again and start a transaction';
$dbh->{AutoCommit} = 0;
$disconnect = 0;
ok $conn->disconnect, 'disconnect again';
is $ping, 0, 'disconnect still should not have pinged';
ok $disconnect, 'It should have called disconnect on the database handle';
$dbh->{AutoCommit} = 1; # Clean up after ourselves.

# DESTROY.
$disconnect = 0;
$rollback   = 0;
ok $conn->DESTROY, 'DESTROY should be fine';
ok !$disconnect, 'Disconnect should not have been called';
ok !$rollback, 'And neither should rollback';

ok my $new = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ), 'Instantiate again';
isnt $new, $conn, 'It should be a different object';

ok $dbh = $new->dbh, 'Connect again';
is $ping, 0, 'New handle, no ping';
$dbh->{AutoCommit} = 0;
ok $new->DESTROY, 'DESTROY with a connector';
ok $disconnect, 'Disconnect should have been called';
$dbh->{AutoCommit} = 1; # Clean up after ourselves.
is $ping, 0, 'Disconnect should not have called ping';

# Check connector args.
ok $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ), 'Instantiate once more';
ok $dbh = $conn->dbh, 'Connect once more';
is $ping, 0, 'Another new handle, no ping';
ok $dbh->{PrintError}, 'PrintError should be true';
ok $dbh->{RaiseError}, 'RaiseError should be true';

ok $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '', {
    PrintError => 0,
    RaiseError => 0,
    AutoCommit => 0,
} ), 'Add attributes to the connect args';

ok $dbh = $conn->dbh, 'Connect with attrs';
is $ping, 0, 'Yet another new handle, another ping';
ok !$dbh->{PrintError}, 'Now PrintError should be false';
ok !$dbh->{RaiseError}, 'And RaiseError should be false';
ok !$dbh->{AutoCommit}, 'And AutoCommit should be false';
ok $conn->in_txn, 'As should in_txn()';

# More dbh.
ok $dbh = $conn->dbh, 'Fetch the database handle again';
is $ping, 1, 'Handle should have been pinged';
isa_ok $dbh, 'DBI::db';
ok !$dbh->{PrintError}, 'PrintError should be false';
ok !$dbh->{RaiseError}, 'RaiseError should be false';

# dbh inside a block.
BLOCK: {
    $mock->mock( ping => sub { pass 'Should not call ping()' });
    is $conn->dbh, $dbh, 'Should get the database handle as usual';
    $mock->mock( ping => sub { fail 'Should not call ping() in a block' });
    local $conn->{_in_run} = 1;
    is $conn->dbh, $dbh, 'Should get the database handle in do block';
    $mock->unmock( 'ping' );
}

# _dbh
is $conn->_dbh, $dbh, '_dbh should work';
is $ping, 1, '_dbh should not have pinged';

# connect
$disconnect = 0;
ok my $odbh = $CLASS->connect('dbi:ExampleP:dummy', '', '', {
    PrintError => 0,
    RaiseError => 1,
    AutoCommit => 0,
}), 'Get a dbh via connect() with same args';
isnt $odbh, $dbh, 'It should not be the same dbh';
$odbh->{AutoCommit} = 1; # Clean up after ourselves.
is $disconnect, 0, 'disconnect() should not have been called';

ok my $ddbh = $CLASS->connect('dbi:ExampleP:dummy', '', '' ),
    'Get dbh with different args';
isnt $ddbh, $dbh, 'It should be a different database handle';
$dbh->{AutoCommit} = 1; # Clean up after ourselves.
is $disconnect, 0, 'disconnect() still should not have been called';

ok $dbh = $CLASS->connect('dbi:ExampleP:dummy', '', '' ),
    'Get dbh with the same args again';
isnt $dbh, $odbh, 'It should be a different database handle';
is $disconnect, 0, 'disconnect() still should not have been called';
$dbh->{AutoCommit} = 1; # Clean up after ourselves.

# disconnect_on_destroy.
DOND: {
    ok my $conn = $CLASS->new('dbi:ExampleP:dummy', '', '' ),
        'Create new connection';
    ok !$conn->disconnect_on_destroy(0), 'Disable disconnect on destroy';
    ok $conn->dbh, 'Get the database handle';
    is $disconnect, 0, 'disconnect() should not have been called';
}

# Apache::DBI.
APACHEDBI: {
    local $INC{'Apache/DBI.pm'} = __FILE__;
    local $ENV{MOD_PERL} = 1;
    local $DBI::connect_via = "Apache::DBI::connect";
    my $dbi_mock = Test::MockModule->new('DBI', no_auto => 1 );
    $dbi_mock->mock( connect   => sub {
        is $DBI::connect_via, 'connect', 'Apache::DBI should be disabled';
        $dbh;
    } );
    $conn->_connect;
}

FORK: {
    ok $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ),
        'Construct for PID tests';
    ok my $dbh = $conn->dbh, 'Get its database handle';

    # Expire based on PID.
    local *$; $$ = -42;
    ok !$dbh->{InactiveDestroy}, 'InactiveDestroy should be false';
    ok my $new_dbh = $conn->dbh, 'Fetch with different PID';
    isnt $new_dbh, $dbh, 'It should be a different handle';
    ok $dbh->{InactiveDestroy}, 'InactiveDestroy should be true for old handle';

    # Do the same for _dbh.
    is $conn->_dbh, $new_dbh, '_dbh should return same dbh';
    $$ = -99;
    ok !$new_dbh->{InactiveDestroy}, 'InactiveDestroy should be false in new handle';
    ok $dbh = $conn->_dbh, 'Call _dbh again';
    isnt $dbh, $new_dbh, 'It should be a new handle';
    ok $new_dbh->{InactiveDestroy}, 'InactiveDestroy should be true for second handle';

    # Expire based on active (!connected).
    $dbh->{Active} = 0;
    ok $new_dbh = $conn->dbh, 'Fetch for inactive handle';
    isnt $new_dbh, $dbh, 'It should be yet another handle';

    # Connection check should be ignored by _dbh.
    $new_dbh->{Active} = 0;
    ok !$new_dbh->{Active}, 'Handle should be inactive';
    isnt $dbh = $conn->_dbh, $new_dbh, '_dbh should not return inactive handle';

    # Check _seems_connected, just to be sane.
    ok $dbh = $conn->dbh, 'Get a new handle';
    ok $conn->_seems_connected, 'Should seem connected';
    $dbh->{Active} = 0;
    ok !$dbh->{Active}, 'Deactivate';
    ok !$conn->_seems_connected, 'Should no longer seem connected';
}

# Connect with threads.
THREAD: {
    ok $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ),
        'Construct for TID tests';
    ok my $dbh = $conn->dbh, 'Get its database handle';

    # Mock up threads.
    local $INC{'threads.pm'} = __FILE__;
    no strict 'refs';
    my $tid = 42;
    local *{'threads::tid'} = sub { $tid };

    # Expire based on TID.
    $conn->{_pid} = -42;
    is $conn->{_pid}, -42, 'pid should be wrong';
    is $conn->{_tid}, undef, 'tid should be undef';
    ok $dbh = $conn->dbh, 'Connect to the database with threads';
    is $conn->{_tid}, 42, 'tid should now be set';
    is $conn->{_pid}, $$, 'pid should be set again';

    # Test how a different tid resets the handle.
    $tid = 43;
    ok my $new_dbh = $conn->dbh, 'Get new threaded handle';
    isnt $new_dbh, $dbh, 'It should be a different handle';

    # Do the same for _dbh.
    is $conn->_dbh, $new_dbh, '_dbh should return same dbh';
    $tid = 99;
    ok $dbh = $conn->_dbh, 'Call _dbh again with new tid';
    isnt $dbh, $new_dbh, 'It should be a new handle';
    is $conn->{_tid}, 99, 'And the tid should be set';
    $conn->DESTROY; # Clean up after ourselves.
}

SKIP: {
    skip 'AutoInactiveDestroy in DBI 1.614 and higher', 5
        unless DBI->VERSION > 1.613;
    my @args = ('dbi:ExampleP:dummy', '', '');
    ok $CLASS->new(@args)->dbh->{AutoInactiveDestroy},
        'AutoInactiveDestroy should be set when no attributes';
    push @args, {};
    ok $CLASS->new(@args)->dbh->{AutoInactiveDestroy},
        'AutoInactiveDestroy should be set when empty attrs';
    $args[3]{RaiseError} = 1;
    ok $CLASS->new(@args)->dbh->{AutoInactiveDestroy},
        'AutoInactiveDestroy should be set when not passed';
    $args[3]{AutoInactiveDestroy} = 1;
    ok $CLASS->new(@args)->dbh->{AutoInactiveDestroy},
        'AutoInactiveDestroy should be set when passed true';
    $args[3]{AutoInactiveDestroy} = 0;
    ok !$CLASS->new(@args)->dbh->{AutoInactiveDestroy},
        'AutoInactiveDestroy should not be true when passed false';
}

HANDLEERROR: {
    # Try with a HandleError param.
    local $ENV{FOO} = 1;
    ok my $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '', {
        HandleError => sub { },
    } ), 'Add HandleError to connect args';
    ok $dbh = $conn->dbh, 'Grab the database handle';
    ok $dbh->{PrintError}, 'PrintError should be true';
    ok $dbh->{HandleError}, 'And HandleError should be true';
    ok !$dbh->{RaiseError}, 'And RaiseError should be false';
}
