use strict; use warnings;

use Test::More tests => 94;
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

# Test with no existing dbh.
my $connect_meth = Hook::Guard->new( \*DBIx::Connector::_connect )->prepend(sub {
    pass '_connect should be called';
});

ok my $dbh = $conn->dbh, 'Fetch the database handle';
ok $dbh->{AutoCommit}, 'We should not be in a txn';
ok !$conn->in_txn, 'in_txn() should know that, too';
ok !$conn->{_in_run}, '_in_run should be false';

# Set up a DBI mocker.
my $ping = 0;
my $dbh_ping_meth = Hook::Guard->new( \*DBI::db::ping )->replace( sub { ++$ping } );

is $conn->{_dbh}, $dbh, 'The dbh should be stored';
is $ping, 0, 'No pings yet';
ok $conn->connected, 'We should be connected';
is $ping, 1, 'Ping should have been called';
ok $conn->txn(sub {
    is $ping, 1, 'Ping should not have been called before the txn';
    ok !shift->{AutoCommit}, 'Inside, we should be in a transaction';
    ok $conn->in_txn, 'We should be in a txn';
    ok $conn->{_in_run}, '_in_run should be true';
    is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
    is $ping, 1, 'ping should not have been called again';
}), 'Do something with no existing handle';
$connect_meth->restore;
ok !$conn->{_in_run}, '_in_run should be false again';
ok $dbh->{AutoCommit}, 'Transaction should be committed';
ok !$conn->in_txn, 'in_txn() should know it';

# Test with instantiated dbh.
is $conn->{_dbh}, $dbh, 'The dbh should be stored';
ok $conn->connected, 'We should be connected';
ok $conn->txn(sub {
    my $dbha = shift;
    is $dbha, $dbh, 'The handle should have been passed';
    is $_, $dbh, 'It should also be in $_';
    is $_, $dbh, 'Should have dbh in $_';
    $ping = 0;
    is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
    $ping = 1;
    ok !$dbha->{AutoCommit}, 'We should be in a transaction';
    ok $conn->in_txn, 'in_txn() should know about it';
}), 'Do something with stored handle';
ok $dbh->{AutoCommit}, 'New transaction should be committed';
ok !$conn->in_txn, 'in_txn() should know it, too';

# Test the return value.
ok my $foo = $conn->txn(sub {
    return (2, 3, 5);
}), 'Do in scalar context';
is $foo, 5, 'The return value should be the last value';

ok $foo = $conn->txn(sub {
    return wantarray ?  (2, 3, 5) : 'scalar';
}), 'Do in scalar context';
is $foo, 'scalar', 'Callback should know when its context is scalar';

ok my @foo = $conn->txn(sub {
    return (2, 3, 5);
}), 'Do in array context';
is_deeply \@foo, [2, 3, 5], 'The return value should be the list';

ok @foo = $conn->txn(sub {
    return wantarray ?  (2, 3, 5) : 'scalar';
}), 'Do in scalar context';
is_deeply \@foo, [2, 3, 5], 'Callback should know when its context is list';

# Test an exception.
eval {  $conn->txn(sub { die 'WTF?' }) };
ok $@, 'We should have died';
ok $dbh->{AutoCommit}, 'New transaction should rolled back';
ok !$conn->in_txn, 'in_txn() should know that';

# Make sure nested calls work.
$conn->txn(sub {
    my $dbh = shift;
    ok !$dbh->{AutoCommit}, 'We should be in a txn';
    ok $conn->in_txn, 'in_txn() should know about it';
    local $dbh->{Active} = 0;
    $conn->txn(sub {
        isnt shift, $dbh, 'Nested txn should not get inactive dbh';
        ok !$dbh->{AutoCommit}, 'Nested txn should be in the txn';
        ok $conn->in_txn, 'in_txn() should know it';
    });
});

# Make sure that it does nothing transactional if we've started the
# transaction.
$dbh = $conn->dbh;
my $driver = $conn->driver;
$driver->begin_work($dbh);
ok !$dbh->{AutoCommit}, 'Transaction should be started';
ok $conn->in_txn, 'in_txn() should know it';
$conn->txn(sub {
    my $dbha = shift;
    is $dbha, $dbh, 'We should have the same database handle';
    is $_, $dbh, 'It should also be in $_';
    $ping = 0;
    is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
    $ping = 1;
    ok !$dbha->{AutoCommit}, 'Transaction should still be going';
    ok $conn->in_txn, 'in_txn() should know it';
});
ok !$dbh->{AutoCommit}, 'Transaction should stil be live after txn';
ok $conn->in_txn, 'in_txn() should know it';
$driver->rollback($dbh);

# Make sure nested calls when ping returns false.
$conn->txn(sub {
    my $dbh = shift;
    ok !$dbh->{AutoCommit}, 'We should be in a txn';
    ok $conn->in_txn, 'in_txn() should know that, too';
    $dbh_ping_meth->replace( sub { 0 } );
    $conn->txn(sub {
        is shift, $dbh, 'Nested txn should get same dbh, even though inactive';
        ok !$dbh->{AutoCommit}, 'Nested txn should be in the txn';
    ok $conn->in_txn, 'in_txn() should know that, too';
    });
});

# Test mode.
$conn->txn(sub {
    is $conn->mode, 'no_ping', 'Default mode should be no_ping';
});

$conn->txn(ping => sub {
    is $conn->mode, 'ping', 'Mode should be "ping" inside ping txn'
});
is $conn->mode, 'no_ping', 'Back outside, should be "no_ping" again';

$conn->txn(fixup => sub {
    is $conn->mode, 'fixup', 'Mode should be "fixup" inside fixup txn'
});
is $conn->mode, 'no_ping', 'Back outside, should be "no_ping" again';

ok $conn->mode('ping'), 'Se mode to "ping"';
$conn->txn(sub {
    is $conn->mode, 'ping', 'Mode should implicitly be "ping"'
});

ok $conn->mode('fixup'), 'Se mode to "fixup"';
$conn->txn(sub {
    is $conn->mode, 'fixup', 'Mode should implicitly be "fixup"'
});

NOEXIT: {
    no warnings;

    my $begin_work_meth = Hook::Guard->new( \*DBIx::Connector::Driver::begin_work )->replace( sub { shift } );
    my $keyword;
    my $commit_meth = Hook::Guard->new( \*DBIx::Connector::Driver::commit )->replace( sub {
        pass "Commit should be called when returning via $keyword"
    });

    # Make sure we don't exit the app via `next` or `last`.
    for my $mode (qw(ping no_ping fixup)) {
        $conn->mode($mode);

        $keyword = 'next';
        ok !$conn->txn(sub { next }), "Return via $keyword should fail";

        $keyword = 'last';
        ok !$conn->txn(sub { last }), "Return via $keyword should fail";
    }
}

# Have the rollback die.
my $dbh_begin_work_meth = Hook::Guard->new( \*DBI::db::begin_work )->replace( sub { return } );
my $dbh_rollback_meth   = Hook::Guard->new( \*DBI::db::rollback )->replace( sub { die 'Rollback WTF' } );

eval { $conn->txn(sub {
    die 'Transaction WTF';
}) };

ok my $err = $@, 'We should have died';
isa_ok $err, 'DBIx::Connector::TxnRollbackError', 'The exception';
like $err, qr/Transaction aborted: Transaction WTF/, 'Should have the transaction error';
like $err, qr/Transaction rollback failed: Rollback WTF/, 'Should have the rollback error';
like $err->rollback_error, qr/Rollback WTF/, 'Should have rollback error';
like $err->error, qr/Transaction WTF/, 'Should have transaction error';

# Try a nested transaction.
eval { $conn->txn(sub {
    local $_->{AutoCommit} = 0;
    $conn->txn(sub { die 'Nested WTF' });
}) };

ok $err = $@, 'We should have died again';
isa_ok $err, 'DBIx::Connector::TxnRollbackError', 'The exception';
like $err->rollback_error, qr/Rollback WTF/, 'Should have rollback error';
like $err->error, qr/Nested WTF/, 'Should have nested transaction error';
ok !ref $err->error, 'The nested error should not be an object';
