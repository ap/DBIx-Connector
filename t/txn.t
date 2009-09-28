#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 23;
#use Test::More 'no_plan';
use Test::MockModule;

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connection';
    use_ok $CLASS or die;
}

ok my $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ),
    'Get a connection';

my $module = Test::MockModule->new($CLASS);

# Test with no cached dbh.
$module->mock( _connect => sub {
    pass '_connect should be called';
    $module->original('_connect')->(@_);
});
ok $conn->txn(sub {
    ok !shift->{AutoCommit}, 'We should be in a transaction';
}), 'Do something with no cached handle';
$module->unmock( '_connect');
ok my $dbh = $conn->dbh, 'Fetch the dbh';
ok $dbh->{AutoCommit}, 'Transaction should be committed';

# Test with cached dbh.
is $conn->{_dbh}, $dbh, 'The dbh should be cached';
ok $conn->connected, 'We should be connected';
ok $conn->txn(sub {
    my $dbha = shift;
    is $dbha, $dbh, 'The cached handle should have been passed';
    ok !$dbha->{AutoCommit}, 'We should be in a transaction';
}), 'Do something with cached handle';

# Test the return value.
ok my $foo = $conn->txn(sub {
    return (2, 3, 5);
}), 'Do in scalar context';
is $foo, 5, 'The return value should be the last value';

ok my @foo = $conn->txn(sub {
    return (2, 3, 5);
}), 'Do in array context';
is_deeply \@foo, [2, 3, 5], 'The return value should be the list';

# Test an exception.
eval {  $conn->txn(sub { die 'WTF?' }) };
ok $@, 'We should have died';

# Test a disconnect.
my $die = 1;
my $calls;
$conn->txn(sub {
    my $dbha = shift;
    $calls++;
    if ($die) {
        is $dbha, $dbh, 'Should have cached dbh';
        $die = 0;
        ok !$dbha->{AutoCommit}, 'We should be in a transaction';
        $dbha->{Active} = 0;
        ok !$dbha->{Active}, 'Disconnect';
        die 'WTF?';
    }
    isnt $dbha, $dbh, 'Should have new dbh';
});

is $calls, 2, 'Sub should have been called twice';

$conn->txn(sub {
    shift;
    is_deeply \@_, [qw(1 2 3)], 'Args should be passed through';
}, qw(1 2 3));
