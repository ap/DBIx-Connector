#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 32;
#use Test::More 'no_plan';
use Test::MockModule;

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connector';
    use_ok $CLASS or die;
}



ok my $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ),
    'Get a connection';

my $module = Test::MockModule->new($CLASS);
my $driver = Test::MockModule->new("$CLASS\::Driver");

# Mock the savepoint driver methods.
$driver->mock( $_ => sub { shift } ) for qw(savepoint release rollback_to);

# Test with no existing dbh.
$module->mock( _connect => sub {
    pass '_connect should be called';
    $module->original('_connect')->(@_);
});

ok my $dbh = $conn->dbh, 'Fetch the database handle';
ok !$conn->{_in_run}, '_in_run should be false';
ok $dbh->{AutoCommit}, 'AutoCommit should be true';
is $conn->{_svp_depth}, 0, 'Depth should be 0';

ok $conn->svp( fixup => sub {
    ok !shift->{AutoCommit}, 'Inside, we should be in a transaction';
    ok $conn->{_in_run}, '_in_run should be true';
    is $conn->{_svp_depth}, 1, 'Depth should be 1';
}), 'Do something with no existing handle';
$module->unmock( '_connect');
ok !$conn->{_in_run}, '_in_run should be false again';
ok $dbh->{AutoCommit}, 'Transaction should be committed';
is $conn->{_svp_depth}, 0, 'Depth should be 0 again';

# Test with instantiated dbh.
is $conn->{_dbh}, $dbh, 'The dbh should be stored';
ok $conn->connected, 'We should be connected';
ok $conn->svp( fixup => sub {
    my $dbha = shift;
    is $dbha, $dbh, 'The handle should have been passed';
    is $_, $dbh, 'It should also be in $_';
    ok !$dbha->{AutoCommit}, 'We should be in a transaction';
}), 'Do something with existing handle';

# Test the return value.
ok my $foo = $conn->svp( fixup => sub {
    return (2, 3, 5);
}), 'Do in scalar context';
is $foo, 5, 'The return value should be the last value';

ok my @foo = $conn->svp( fixup => sub {
    return (2, 3, 5);
}), 'Do in array context';
is_deeply \@foo, [2, 3, 5], 'The return value should be the list';

# Test args.
$conn->svp( fixup => sub {
    shift;
    is_deeply \@_, [qw(1 2 3)], 'Args should be passed through from implicit txn';
}, qw(1 2 3));

$conn->txn( fixup => sub {
    $conn->svp( fixup => sub {
        shift;
        is_deeply \@_, [qw(1 2 3)], 'Args should be passed inside explicit txn';
    }, qw(1 2 3));
});

# Make sure nested calls work.
$conn->svp( fixup => sub {
    my $dbh = shift;
    ok !$dbh->{AutoCommit}, 'Inside, we should be in a transaction';
    is $conn->{_svp_depth}, 1, 'Depth should be 1';
    local $dbh->{Active} = 0;
    $conn->svp( fixup => sub {
        is shift, $dbh, 'Nested svp_ping_run should always get the current dbh';
        ok !$dbh->{AutoCommit}, 'Nested txn_runup should be in the txn';
        is $conn->{_svp_depth}, 2, 'Depth should be 2';
    });
    is $conn->{_svp_depth}, 1, 'Depth should be 1 again';
});
