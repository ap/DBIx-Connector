#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 90;
#use Test::More 'no_plan';
use Test::MockModule;
use Carp;

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connection';
    use_ok $CLASS or die;
    $SIG{__WARN__} = \&Carp::cluck;
}

# Try the basics.
ok my $conn = $CLASS->new, 'Create new connection object';
isa_ok $conn, $CLASS;
ok !$conn->connected, 'Should not be connected';
eval { $conn->dbh };
ok $@, 'Should get error for no connection args';
ok $conn->disconnect, 'Disconnect should not complain';

# Set some connect args.
ok $conn = $CLASS->new( 'whatever', 'you', 'want' ),
    'Construct object with bad args';
eval { $conn->connect };
ok $@, 'Should get error for bad args';

# Connect f'real.
ok $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ),
    'Construct connection with good args';
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
ok $conn->connected, 'We should be connected';

# Disconnect.
my $mock = Test::MockModule->new( ref $dbh, no_auto => 1 );
my ($rollback, $disconnect) = (0, 0);
$mock->mock( rollback   => sub { ++$rollback } );
$mock->mock( disconnect => sub { ++$disconnect } );
ok $conn->disconnect, 'disconnect should execute without error';
ok $disconnect, 'It should have called disconnect on the database handle';
ok !$rollback,  'But not rollback';
is $conn->{_dbh}, undef, 'The _dbh accessor should now return undef';

# Start a transaction.
ok $dbh = $conn->dbh, 'Connect again and start a transaction';
$dbh->{AutoCommit} = 0;
$disconnect = 0;
ok $conn->disconnect, 'disconnect again';
ok $disconnect, 'It should have called disconnect on the database handle';
ok $rollback,   'And it should have called rollback';
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
$dbh->{AutoCommit} = 0;
ok $new->DESTROY, 'DESTROY with a connection';
ok $disconnect, 'Disconnect should have been called';
ok $rollback,   'And so should rollback';
$dbh->{AutoCommit} = 1; # Clean up after ourselves.

# Check connection args.
ok $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ), 'Instantiate once more';
ok $dbh = $conn->dbh, 'Connect once more';
ok $dbh->{PrintError}, 'PrintError should be set';
ok !$dbh->{RaiseError}, 'RaiseError should not be set';

ok $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '', {
    PrintError => 0,
    RaiseError => 1
} ), 'Add attributes to the connect args';

ok $dbh = $conn->dbh, 'Connect with attrs';
ok !$dbh->{PrintError}, 'Now PrintError should not be set';
ok $dbh->{RaiseError}, 'But RaiseError should be set';

# More dbh.
ok $dbh = $conn->dbh, 'Fetch the database handle';
isa_ok $dbh, 'DBI::db';
ok !$dbh->{PrintError}, 'PrintError should not be set';
ok $dbh->{RaiseError}, 'RaiseError should be set';

# _dbh
is $conn->_dbh, $dbh, '_dbh should work';

# connect
ok my $odbh = $CLASS->connect('dbi:ExampleP:dummy', '', '', {
    PrintError => 0,
    RaiseError => 1
}), 'Get a dbh via connect() with same args';
is $odbh, $dbh, 'It should be the cached dbh';

ok $odbh = $CLASS->connect('dbi:ExampleP:dummy', '', '' ),
    'Get dbh with different args';
isnt $odbh, $dbh, 'It should be a different database handle';

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
    local $$ = -42;
    ok !$dbh->{InactiveDestroy}, 'InactiveDestroy should be false';
    ok my $new_dbh = $conn->dbh, 'Fetch with different PID';
    isnt $new_dbh, $dbh, 'It should be a different handle';
    ok $dbh->{InactiveDestroy}, 'InactiveDestroy should be true for old handle';

    # Do the same for _dbh.
    is $conn->_dbh, $new_dbh, '_dbh should return cached dbh';
    $$ = -99;
    ok !$new_dbh->{InactiveDestroy}, 'InactiveDestroy should be false in new handle';
    ok $dbh = $conn->_dbh, 'Call _dbh again';
    isnt $dbh, $new_dbh, 'It should be a new handle';
    ok $new_dbh->{InactiveDestroy}, 'InactiveDestroy should be true for second handle';

    # Expire based on active (!connected).
    $dbh->{Active} = 0;
    ok $new_dbh = $conn->dbh, 'Fetch for inactive handle';
    isnt $new_dbh, $dbh, 'It should be yet another handle';

    # Connection check should be ignored bh _dbh.
    $new_dbh->{Active} = 0;
    ok !$new_dbh->{Active}, 'Handle should be inactive';
    is $conn->_dbh, $new_dbh, '_dbh should return inactive handle';

    # Check _verify_pid, just to be sane.
    ok $conn->_verify_pid, '_verify_pid should return true';
    $$ = -40;
    ok !$new_dbh->{InactiveDestroy}, 'InactiveDestroy should be false';
    ok !$conn->_verify_pid, '_verify_pid should return false when pid changes';
    ok $new_dbh->{InactiveDestroy}, 'InactiveDestroy should now be true';

    # Check _seems_connected.
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
    is $conn->_dbh, $new_dbh, '_dbh should return cached dbh';
    $tid = 99;
    ok $dbh = $conn->_dbh, 'Call _dbh again with new tid';
    isnt $dbh, $new_dbh, 'It should be a new handle';
    is $conn->{_tid}, 99, 'And the tid should be set';
    $conn->DESTROY; # Clean up after ourselves.
}