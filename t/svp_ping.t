#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 52;
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
ok !$conn->in_txn, 'in_txn() should return false';
is $conn->{_svp_depth}, 0, 'Depth should be 0';

# This should just pass to txn.
ok $conn->svp( ping => sub {
    ok !shift->{AutoCommit}, 'Inside, we should be in a transaction';
    ok $conn->in_txn, 'in_txn() should know all about it';
    ok $conn->{_in_run}, '_in_run should be true';
    is $conn->{_svp_depth}, 0, 'Depth should be 0';
}), 'Do something with no existing handle';
$module->unmock( '_connect');
ok !$conn->{_in_run}, '_in_run should be false again';
ok $dbh->{AutoCommit}, 'Transaction should be committed';
ok !$conn->in_txn, 'in_txn() should know know that, too';
is $conn->{_svp_depth}, 0, 'Depth should still be 0 again';

# Test with instantiated dbh.
is $conn->{_dbh}, $dbh, 'The dbh should be stored';
ok $conn->connected, 'We should be connected';
ok $conn->svp( ping => sub {
    my $dbha = shift;
    is $dbha, $dbh, 'The handle should have been passed';
    is $_, $dbh, 'It should also be in $_';
    ok !$dbha->{AutoCommit}, 'We should be in a transaction';
    ok $conn->in_txn, 'in_txn() should know all about it';
}), 'Do something with existing handle';

# Run the same test from inside a transaction, so we're sure that the svp
# code executes properly. This is because svp must be called from inside a
# txn. If it's not, it just dispatches to txn() and returns.
ok $conn->txn(ping => sub {
    $conn->svp(sub {
        my $dbha = shift;
        is $conn->{_mode}, 'ping', 'Should be in ping mode';
        is $dbha, $dbh, 'The handle should have been passed';
        is $_, $dbh, 'It should also be in $_';
        ok !$dbha->{AutoCommit}, 'We should be in a transaction';
        ok $conn->in_txn, 'in_txn() should know it, too';
    });
}), 'Do something inside a transaction';

# Test the return value. Gotta do it inside a transaction.
$conn->txn(sub {
    ok my $foo = $conn->svp( ping => sub {
        return (2, 3, 5);
    }), 'Do in scalar context';
    is $foo, 5, 'The return value should be the last value';

    ok my @foo = $conn->svp( ping => sub {
        return (2, 3, 5);
    }), 'Do in array context';
    is_deeply \@foo, [2, 3, 5], 'The return value should be the list';
});

# Make sure nested calls work.
$conn->svp( ping => sub {
    my $dbh = shift;
    ok !$dbh->{AutoCommit}, 'Inside, we should be in a transaction';
    ok $conn->in_txn, 'in_txn() should know all about it';
    is $conn->{_svp_depth}, 0, 'Depth should be 0';
    local $dbh->{Active} = 0;
    $conn->svp( ping => sub {
        is shift, $dbh, 'Nested svp should always get the current dbh';
        ok !$dbh->{AutoCommit}, 'Nested txn_runup should be in the txn';
    ok $conn->in_txn, 'in_txn() should know all about it, too';
        is $conn->{_svp_depth}, 1, 'Depth should be 1';
    });
    is $conn->{_svp_depth}, 0, 'Depth should be 0 again';
});

$conn->svp(ping => sub {
    # Check exception handling.
    $@ = 'foo';
    ok $conn->svp(ping => sub {
        die 'WTF!';
    }, sub {
        like $_, qr/WTF!/, 'Should catch exception';
        like shift, qr/WTF!/, 'catch arg should also be the exception';
    }), 'Catch and handle an exception';
    is $@, 'foo', '$@ should not be changed';

    ok $conn->svp(ping => sub {
        die 'WTF!';
    }, catch => sub {
        like $_, qr/WTF!/, 'Should catch another exception';
        like shift, qr/WTF!/, 'catch arg should also be the new exception';
    }), 'Catch and handle another exception';
    is $@, 'foo', '$@ still should not be changed';

    eval { $conn->svp(ping => sub { die 'WTF!' }, catch => sub { die 'OW!' }) };
    ok my $e = $@, 'Should catch exception thrown by catch';
    like $e, qr/OW!/, 'And it should be the expected exception';

});
