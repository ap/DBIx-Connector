#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 98;
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
ok $conn->svp(sub {
    ok !shift->{AutoCommit}, 'Inside, we should be in a transaction';
    ok $conn->in_txn, 'in_txn() should know it, too';
    ok $conn->{_in_run}, '_in_run should be true';
    is $conn->{_svp_depth}, 0, 'Depth should still be 0';
}), 'Do something with no existing handle';
$module->unmock( '_connect');
ok !$conn->{_in_run}, '_in_run should be false again';
ok $dbh->{AutoCommit}, 'Transaction should be committed';
ok !$conn->in_txn, 'in_txn() should know it, too';
is $conn->{_svp_depth}, 0, 'Depth should be 0 again';

# Test with instantiated dbh.
is $conn->{_dbh}, $dbh, 'The dbh should be stored';
ok $conn->connected, 'We should be connected';
ok $conn->svp(sub {
    my $dbha = shift;
    is $dbha, $dbh, 'The handle should have been passed';
    is $_, $dbh, 'It should also be in $_';
    ok !$dbha->{AutoCommit}, 'We should be in a transaction';
    ok $conn->in_txn, 'in_txn() should know it, too';
}), 'Do something with stored handle';

# Run the same test from inside a transaction, so we're sure that the svp
# code executes properly. This is because svp must be called from inside a
# txn. If it's not, it just dispatches to txn() and returns.
ok $conn->txn(sub {
    $conn->svp(sub {
        my $dbha = shift;
        is $dbha, $dbh, 'The handle should have been passed';
        is $_, $dbh, 'It should also be in $_';
        ok !$dbha->{AutoCommit}, 'We should be in a transaction';
        ok $conn->in_txn, 'in_txn() should know it, too';
    });
}), 'Do something inside a transaction';

# Test the return value. Gotta do it inside a transaction.
$conn->txn(sub {
    ok my $foo = $conn->svp(sub {
        return (2, 3, 5);
    }), 'Do in scalar context';
    is $foo, 5, 'The return value should be the last value';

    ok $foo = $conn->svp(sub {
        return wantarray ?  (2, 3, 5) : 'scalar';
    }), 'Do in scalar context';
    is $foo, 'scalar', 'Callback should know when its context is scalar';

    ok my @foo = $conn->svp(sub {
        return (2, 3, 5);
    }), 'Do in array context';
    is_deeply \@foo, [2, 3, 5], 'The return value should be the list';

    ok @foo = $conn->svp(sub {
        return wantarray ?  (2, 3, 5) : 'scalar';
    }), 'Do in array context';
    is_deeply \@foo, [2, 3, 5], 'Callback should know when its context is list';
});

# Make sure nested calls work.
$conn->svp(sub {
    my $dbh = shift;
    ok !$dbh->{AutoCommit}, 'Inside, we should be in a transaction';
    ok $conn->in_txn, 'in_txn() should know it, too';
    is $conn->{_svp_depth}, 0, 'Depth should be 0';
    local $dbh->{Active} = 0;
    $conn->svp(sub {
        is shift, $dbh, 'Nested svp should always get the current dbh';
        ok !$dbh->{AutoCommit}, 'Nested txn should be in the txn';
        ok $conn->in_txn, 'in_txn() should know it, too';
        is $conn->{_svp_depth}, 1, 'Depth should be 1';
        $conn->svp(sub {
            is shift, $dbh, 'Souble nested svp should get the current dbh';
            ok !$dbh->{AutoCommit}, 'Double nested txn should be in the txn';
            ok $conn->in_txn, 'in_txn() should know it, too';
            is $conn->{_svp_depth}, 2, 'Depth should be 2';
        });
    });
    is $conn->{_svp_depth}, 0, 'Depth should be 0 again';
});

$conn->txn(sub {
    # Check exception handling.
    $@ = 'foo';
    ok $conn->svp(sub {
        die 'WTF!';
    }, sub {
        like $_, qr/WTF!/, 'Should catch exception';
        like shift, qr/WTF!/, 'catch arg should also be the exception';
    }), 'Catch and handle an exception';
    is $@, 'foo', '$@ should not be changed';

    ok $conn->svp(sub {
        die 'WTF!';
    }, catch => sub {
        like $_, qr/WTF!/, 'Should catch another exception';
        like shift, qr/WTF!/, 'catch arg should also be the new exception';
    }), 'Catch and handle another exception';
    is $@, 'foo', '$@ still should not be changed';

    eval { $conn->svp(sub { die 'WTF!' }, catch => sub { die 'OW!' }) };
    ok my $e = $@, 'Should catch exception thrown by catch';
    like $e, qr/OW!/, 'And it should be the expected exception';

    # Test mode.
    $conn->svp(sub {
        is $conn->mode, 'no_ping', 'Default mode should be no_ping';
    });

    $conn->svp(ping => sub {
        is $conn->mode, 'ping', 'Mode should be "ping" inside ping svp'
    });
    is $conn->mode, 'no_ping', 'Back outside, should be "no_ping" again';

    $conn->svp(fixup => sub {
        is $conn->mode, 'fixup', 'Mode should be "fixup" inside fixup svp'
    });
    is $conn->mode, 'no_ping', 'Back outside, should be "no_ping" again';

    ok $conn->mode('ping'), 'Se mode to "ping"';
    $conn->svp(sub {
        is $conn->mode, 'ping', 'Mode should implicitly be "ping"'
    });

    ok $conn->mode('fixup'), 'Se mode to "fixup"';
    $conn->svp(sub {
        is $conn->mode, 'fixup', 'Mode should implicitly be "fixup"'
    });
});

NOEXIT: {
    no warnings;

    $driver->mock(begin_work => sub { shift });
    my $keyword;
    $driver->mock(commit => sub {
        pass "Commit should be called when returning via $keyword"
    });

    $conn->txn(sub {
        # Make sure we don't exit the app via `next` or `last`.
        for my $mode qw(ping no_ping fixup) {
            $conn->mode($mode);

            $keyword = 'next';
            ok !$conn->svp(sub { next }), "Return via $keyword should fail";

            $keyword = 'last';
            ok !$conn->svp(sub { last }), "Return via $keyword should fail";
        }
    });
}

# Have the rollback_to die.
my $dbi_mock = Test::MockModule->new(ref $dbh, no_auto => 1);
$dbi_mock->mock(begin_work => undef );
$dbi_mock->mock(rollback   => undef );
$driver->mock( rollback_to => sub { die 'ROLLBACK TO WTF' });
$dbh->{AutoCommit} = 0; # Ensure we run a savepoint.
eval { $conn->svp(sub { die 'Savepoint WTF' }) };

ok my $err = $@, 'We should have died';
isa_ok $err, 'DBIx::Connector::SvpRollbackError', 'The exception';
like $err, qr/Savepoint aborted: Savepoint WTF/, 'Should have the savepoint error';
like $err, qr/Savepoint rollback failed: ROLLBACK TO WTF/,
    'Should have the savepoint rollback error';
like $err->rollback_error, qr/ROLLBACK TO WTF/, 'Should have rollback error';
like $err->error, qr/Savepoint WTF/, 'Should have savepoint error';

# Try a nested savepoint.
eval { $conn->svp(sub {
    $conn->svp(sub { die 'Nested WTF' });
}) };

ok $err = $@, 'We should have died again';
isa_ok $err, 'DBIx::Connector::SvpRollbackError', 'The exception';
like $err->rollback_error, qr/ROLLBACK TO WTF/, 'Should have rollback error';
like $err->error, qr/Nested WTF/, 'Should have nested savepoint error';

# Now try a savepoint rollback failure *and* a transaction rollback failure.
$dbi_mock->mock(rollback => sub { die 'Rollback WTF' } );
$dbh->{AutoCommit} = 1;
eval {
    $conn->txn(sub {
        local $dbh->{AutoCommit} = 0;
        $conn->svp(sub { die 'Savepoint WTF' });
    })
};

ok $err = $@, 'We should have died';
isa_ok $err, 'DBIx::Connector::TxnRollbackError', 'The exception';
like $err->rollback_error, qr/Rollback WTF/, 'Should have rollback error';
isa_ok $err->error, 'DBIx::Connector::SvpRollbackError', 'The savepoint errror';
like $err, qr/Transaction aborted: Savepoint aborted: Savepoint WTF/,
    'Stringification should have savepoint errror';
like $err, qr/Savepoint rollback failed: ROLLBACK TO WTF/,
    'Stringification should have savepoint rollback failure';
like $err, qr/Transaction rollback failed: Rollback WTF/,
    'Stringification should have transaction rollback failure';
