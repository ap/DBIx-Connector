#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 47;
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

# Test with no cached dbh.
$module->mock( _connect => sub {
    pass '_connect should be called';
    $module->original('_connect')->(@_);
});

ok my $dbh = $conn->dbh, 'Fetch the database handle';
ok $dbh->{AutoCommit}, 'We should not be in a txn';
ok !$conn->{_in_do}, '_in_do should be false';

ok $conn->txn_do(sub {
    ok !shift->{AutoCommit}, 'Inside, we should be in a transaction';
    ok !$conn->{AutoCommit}, 'We should be in a txn';
    ok $conn->{_in_do}, '_in_do should be true';
}), 'Do something with no cached handle';
$module->unmock( '_connect');
ok !$conn->{_in_do}, '_in_do should be false again';
ok $dbh->{AutoCommit}, 'Transaction should be committed';

# Test with cached dbh.
is $conn->{_dbh}, $dbh, 'The dbh should be cached';
ok $conn->connected, 'We should be connected';
ok $conn->txn_do(sub {
    my $dbha = shift;
    is $dbha, $dbh, 'The cached handle should have been passed';
    ok !$dbha->{AutoCommit}, 'We should be in a transaction';
}), 'Do something with cached handle';
ok $dbh->{AutoCommit}, 'New transaction should be committed';

# Test the return value.
ok my $foo = $conn->txn_do(sub {
    return (2, 3, 5);
}), 'Do in scalar context';
is $foo, 5, 'The return value should be the last value';

ok my @foo = $conn->txn_do(sub {
    return (2, 3, 5);
}), 'Do in array context';
is_deeply \@foo, [2, 3, 5], 'The return value should be the list';

# Test an exception.
eval {  $conn->txn_do(sub { die 'WTF?' }) };
ok $@, 'We should have died';
ok $dbh->{AutoCommit}, 'New transaction should rolled back';

# Test a disconnect.
my $die = 1;
my $calls;
$conn->txn_do(sub {
    my $dbha = shift;
    ok !$dbha->{AutoCommit}, 'We should be in a transaction';
    $calls++;
    if ($die) {
        is $dbha, $dbh, 'Should have cached dbh';
        $die = 0;
        $dbha->{Active} = 0;
        ok !$dbha->{Active}, 'Disconnect';
        die 'WTF?';
    }
    isnt $dbha, $dbh, 'Should have new dbh';
});

ok $dbh = $conn->dbh, 'Get the new handle';
ok $dbh->{AutoCommit}, 'New transaction should be committed';

is $calls, 2, 'Sub should have been called twice';

# Test disconnect and die.
$calls = 0;
eval {
    $conn->txn_do(sub {
        my $dbha = shift;
        ok !$dbha->{AutoCommit}, 'We should be in a transaction';
        $dbha->{Active} = 0;
        if ($calls++) {
            die 'OMGWTF?';
        } else {
            is $dbha, $dbh, 'Should have cached dbh again';
            die 'Disconnected';
        }
    });
};
ok my $err = $@, 'We should have died';
like $@, qr/OMGWTF[?]/, 'We should have killed ourselves';
is $calls, 2, 'Sub should have been called twice';

# Test args.
ok $dbh = $conn->dbh, 'Get the new handle';
$conn->txn_do(sub {
    shift;
    is_deeply \@_, [qw(1 2 3)], 'Args should be passed through';
}, qw(1 2 3));

# Make sure nested calls work.
$conn->txn_do(sub {
    my $dbh = shift;
    ok !$conn->{AutoCommit}, 'We should be in a txn';
    local $dbh->{Active} = 0;
    $conn->txn_do(sub {
        is shift, $dbh, 'Nested txn_do should get same dbh, even though inactive';
        ok !$conn->{AutoCommit}, 'Nested txn_do should be in the txn';
    });
});

# Make sure that it does nothing transactional if we've started the
# transaction.
my $driver = $conn->driver;
$driver->begin_work($dbh);
ok !$dbh->{AutoCommit}, 'Transaction should be started';
$conn->txn_do(sub {
    my $dbha = shift;
    is $dbha, $dbh, 'We should have the same database handle';
    ok !$dbha->{AutoCommit}, 'Transaction should still be going';
});
ok !$dbh->{AutoCommit}, 'Transaction should stil be live after txn_do';
$driver->rollback($dbh);
