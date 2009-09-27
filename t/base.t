#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 60;
#use Test::More 'no_plan';
use Test::MockModule;

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connection';
    use_ok $CLASS or die;
}

# Try the basics.
ok my $conn = $CLASS->new, 'Create new connection object';
isa_ok $conn, $CLASS;
ok !$conn->connect_args, 'Should have no connect_args';
ok !$conn->connected, 'Should not be connected';
eval { $conn->connect };
ok $@, 'Should get error for no connection args';
ok $conn->disconnect, 'Disconnect should not complain';

# Set some connect args.
ok $conn->connect_args( 'whatever', 'you', 'want' ),
    'Set bogus connect args';
is_deeply [ $conn->connect_args ], [ 'whatever', 'you', 'want' ],
    'connect_args should be set';
eval { $conn->connect };
ok $@, 'Should get error for bad args';

# Try a connect f'real.
ok $conn = $CLASS->new( connect_args => [ 'dbi:ExampleP:dummy', '', '' ] ),
    'Construct connection with connect_args';
isa_ok $conn, $CLASS;
is_deeply [ $conn->connect_args ], [ 'dbi:ExampleP:dummy', '', '' ],
    'connect_args should be properly set';

# Connect.
is $conn->{_tid}, undef, 'tid should be undef';
is $conn->{_pid}, undef, 'pid should be undef';
ok my $dbh = $conn->connect, 'Connect to the database';
isa_ok $dbh, 'DBI::db';
is $conn->{_dbh}, $dbh, 'The _dbh private attribute should be populated';
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
ok !$rollback, 'But not rollback';
is $conn->{_dbh}, undef, 'The _dbh accessor should now return undef';

# Start a transaction.
ok $dbh = $conn->connect, 'Connect again and start a transaction';
$dbh->{AutoCommit} = 0;
$disconnect = 0;
ok $conn->disconnect, 'disconnect again';
ok $disconnect, 'It should have called disconnect on the database handle';
ok $rollback, 'And it should have called rollback';
$dbh->{AutoCommit} = 1; # Clean up after ourselves.

# DESTROY.
$disconnect = 0;
$rollback   = 0;
ok $conn->DESTROY, 'DESTROY should be fine';
ok !$disconnect, 'Disconnect should not have been called';
ok !$rollback, 'And neither should rollback';

ok $dbh = $conn->connect, 'Connect again';
$dbh->{AutoCommit} = 0;
ok $conn->DESTROY, 'DESTROY with a connection';
ok $disconnect, 'Disconnect should have been called';
ok $rollback, 'And so should rollback';
$dbh->{AutoCommit} = 1; # Clean up after ourselves.

# connect_args.
ok $dbh = $conn->connect, 'Connect once more';
ok $dbh->{PrintError}, 'PrintError should be set';
ok !$dbh->{RaiseError}, 'RaiseError should not be set';

ok $conn->disconnect, 'Disconnect';
ok $conn->connect_args(
    $conn->connect_args, { PrintError => 0, RaiseError => 1 }
), 'Add attributes to the connect args';

ok $dbh = $conn->connect, 'Connect with attrs';
ok !$dbh->{PrintError}, 'Now PrintError should not be set';
ok $dbh->{RaiseError}, 'But RaiseError should be set';

# dbh.
ok $dbh = $conn->dbh, 'Fetch the database handle';
isa_ok $dbh, 'DBI::db';
ok !$dbh->{PrintError}, 'PrintError should not be set';
ok $dbh->{RaiseError}, 'RaiseError should be set';

FORK: {
    # Expire based on PID.
    local $$ = -42;
    ok !$dbh->{InactiveDestroy}, 'InactiveDestroy should be false';
    ok my $new_dbh = $conn->dbh, 'Fetch with different PID';
    isnt $new_dbh, $dbh, 'It should be a different handle';
    ok $dbh->{InactiveDestroy}, 'InactiveDestroy should be true for old handle';

    # Expire based on active (!connected).
    $new_dbh->{Active} = 0;
    ok $dbh = $conn->dbh, 'Fetch for inactive handle';
    isnt $dbh, $new_dbh, 'It should be yet another handle';
}

# Connect with threads.
THREAD: {
    local $INC{'threads.pm'} = __FILE__;
    no strict 'refs';
    my $tid = 42;
    local *{'threads::tid'} = sub { $tid };
    $conn->{_pid} = undef;
    is $conn->{_pid}, undef, 'pid should be undef again';
    ok my $dbh = $conn->connect, 'Connect to the database with threads';
    is $conn->{_tid}, 42, 'tid should now be set';
    is $conn->{_pid}, $$, 'pid should be set again';

    # Test how a different tid resets the handle.
    $tid = 43;
    ok my $new_dbh = $conn->dbh, 'Get new threaded handle';
    isnt $new_dbh, $dbh, 'It should be a different handle';
}
