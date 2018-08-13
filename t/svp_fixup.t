#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 42;
#use Test::More 'no_plan';
use lib 't/lib';
use Hook::Guard;

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connector';
    use_ok $CLASS or die;
}

ok my $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ),
    'Get a connection';

# Mock the savepoint driver methods.
my @driver_meth = map Hook::Guard->new( $_ )->replace( sub { shift } ),
    do { package DBIx::Connector::Driver; \*savepoint, \*release, \*rollback_to };

# Test with no existing dbh.
my $connect_meth = Hook::Guard->new( \*DBIx::Connector::_connect )->prepend(sub {
    pass '_connect should be called';
});

ok my $dbh = $conn->dbh, 'Fetch the database handle';
ok !$conn->{_in_run}, '_in_run should be false';
ok $dbh->{AutoCommit}, 'AutoCommit should be true';
ok !$conn->in_txn, 'in_txn() should know it, too';
is $conn->{_svp_depth}, 0, 'Depth should be 0';

# This should just pass to txn.
ok $conn->svp( fixup => sub {
    ok !shift->{AutoCommit}, 'Inside, we should be in a transaction';
    ok $conn->in_txn, 'in_txn() should know it that';
    ok $conn->{_in_run}, '_in_run should be true';
    is $conn->{_svp_depth}, 0, 'Depth should still be 0';
}), 'Do something with no existing handle';
$connect_meth->restore;
ok !$conn->{_in_run}, '_in_run should be false again';
ok $dbh->{AutoCommit}, 'Transaction should be committed';
ok !$conn->in_txn, 'And in_txn() should know it';
is $conn->{_svp_depth}, 0, 'Depth should be 0 again';

# Test with instantiated dbh.
is $conn->{_dbh}, $dbh, 'The dbh should be stored';
ok $conn->connected, 'We should be connected';
ok $conn->svp( fixup => sub {
    my $dbha = shift;
    is $dbha, $dbh, 'The handle should have been passed';
    is $_, $dbh, 'It should also be in $_';
    ok !$dbha->{AutoCommit}, 'We should be in a transaction';
    ok $conn->in_txn, 'in_txn() should know all about it';
}), 'Do something with existing handle';

# Run the same test from inside a transaction, so we're sure that the svp
# code executes properly. This is because svp must be called from inside a
# txn. If it's not, it just dispatches to txn() and returns.
ok $conn->txn(fixup => sub {
    $conn->svp(sub {
        my $dbha = shift;
        is $conn->{_mode}, 'fixup', 'Should be in fixup mode';
        is $dbha, $dbh, 'The handle should have been passed';
        is $_, $dbh, 'It should also be in $_';
        ok !$dbha->{AutoCommit}, 'We should be in a transaction';
        ok $conn->in_txn, 'in_txn() should know it, too';
    });
}), 'Do something inside a transaction';

# Test the return value. Gotta do it inside a transaction.
$conn->txn(sub {
    ok my $foo = $conn->svp( fixup => sub {
        return (2, 3, 5);
    }), 'Do in scalar context';
    is $foo, 5, 'The return value should be the last value';

    ok my @foo = $conn->svp( fixup => sub {
        return (2, 3, 5);
    }), 'Do in array context';
    is_deeply \@foo, [2, 3, 5], 'The return value should be the list';
});

# Make sure nested calls work.
$conn->svp( fixup => sub {
    my $dbh = shift;
    ok !$dbh->{AutoCommit}, 'Inside, we should be in a transaction';
    ok $conn->in_txn, 'in_txn() should know all about it';
    is $conn->{_svp_depth}, 0, 'Depth should be 0';
    local $dbh->{Active} = 0;
    $conn->svp( fixup => sub {
        is shift, $dbh, 'Nested svp should always get the current dbh';
        ok !$dbh->{AutoCommit}, 'Nested txn_runup should be in the txn';
    ok $conn->in_txn, 'in_txn() should know all about it';
        is $conn->{_svp_depth}, 1, 'Depth should be 1';
    });
    is $conn->{_svp_depth}, 0, 'Depth should be 0 again';
});
