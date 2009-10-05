#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 31;
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

# Test with no cached dbh.
$module->mock( _connect => sub {
    pass '_connect should be called';
    $module->original('_connect')->(@_);
});

ok my $dbh = $conn->dbh, 'Fetch the database handle';
ok !$conn->{_in_do}, '_in_do should be false';
ok $dbh->{AutoCommit}, 'AutoCommit should be true';
is $conn->{_svp_depth}, 0, 'Depth should be 0';

ok $conn->svp_do(sub {
    ok !shift->{AutoCommit}, 'Inside, we should be in a transaction';
    ok $conn->{_in_do}, '_in_do should be true';
    is $conn->{_svp_depth}, 1, 'Depth should be 1';
}), 'Do something with no cached handle';
$module->unmock( '_connect');
ok !$conn->{_in_do}, '_in_do should be false again';
ok $dbh->{AutoCommit}, 'Transaction should be committed';
is $conn->{_svp_depth}, 0, 'Depth should be 0 again';

# Test with cached dbh.
is $conn->{_dbh}, $dbh, 'The dbh should be cached';
ok $conn->connected, 'We should be connected';
ok $conn->svp_do(sub {
    my $dbha = shift;
    is $dbha, $dbh, 'The cached handle should have been passed';
    ok !$dbha->{AutoCommit}, 'We should be in a transaction';
}), 'Do something with cached handle';

# Test the return value.
ok my $foo = $conn->svp_do(sub {
    return (2, 3, 5);
}), 'Do in scalar context';
is $foo, 5, 'The return value should be the last value';

ok my @foo = $conn->svp_do(sub {
    return (2, 3, 5);
}), 'Do in array context';
is_deeply \@foo, [2, 3, 5], 'The return value should be the list';

# Test args.
$conn->svp_do(sub {
    shift;
    is_deeply \@_, [qw(1 2 3)], 'Args should be passed through from implicit txn';
}, qw(1 2 3));

$conn->txn_do(sub {
    $conn->svp_do(sub {
        shift;
        is_deeply \@_, [qw(1 2 3)], 'Args should be passed inside explicit txn';
    }, qw(1 2 3));
});

# Make sure nested calls work.
$conn->svp_do(sub {
    my $dbh = shift;
    ok !$dbh->{AutoCommit}, 'Inside, we should be in a transaction';
    is $conn->{_svp_depth}, 1, 'Depth should be 1';
    local $dbh->{Active} = 0;
    $conn->svp_do(sub {
        is shift, $dbh, 'Nested svp_do should get same dbh, even though inactive';
        ok !$dbh->{AutoCommit}, 'Nested txn_do should be in the txn';
        is $conn->{_svp_depth}, 2, 'Depth should be 2';
    });
    is $conn->{_svp_depth}, 1, 'Depth should be 1 again';
});
