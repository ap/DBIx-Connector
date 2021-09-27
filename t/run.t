#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 59;
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

ok $conn->run(sub {
    ok shift->{AutoCommit}, 'Inside, we should not be in a transaction';
    ok !$conn->in_txn, 'in_txn() should know it, too';
    ok $conn->{_in_run}, '_in_run should be true';
}), 'Do something with no existing handle';

# Test with instantiated dbh.
$connect_meth->restore;
ok my $dbh = $conn->dbh, 'Fetch the dbh';

# Set up a DBI mocker.
my $ping = 0;
my $dbh_ping_meth = Hook::Guard->new( \*DBI::db::ping )->replace( sub { ++$ping } );

is $conn->{_dbh}, $dbh, 'The dbh should be the stored';
is $ping, 0, 'No pings yet';
ok $conn->connected, 'We should be connected';
is $ping, 1, 'Ping should have been called';
ok $conn->run(sub {
    is $ping, 1, 'Ping should not have been called before the run';
    is shift, $dbh, 'The database handle should have been passed';
    is $_, $dbh, 'Should have dbh in $_';
    is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
    is $ping, 1, 'ping should not have been called again';
    $dbh->{Active} = 0;
    isnt $conn->dbh, $dbh, 'Should get different dbh if after disconnect';
}), 'Do something with handle';

# Test the return value.
$dbh = $conn->dbh;
ok my $foo = $conn->run(sub {
    return (2, 3, 5);
}), 'Do in scalar context';
is $foo, 5, 'The return value should be the last value';

ok $foo = $conn->run(sub {
    return wantarray ?  (2, 3, 5) : 'scalar';
}), 'Do in scalar context';
is $foo, 'scalar', 'Callback should know when its context is scalar';

ok my @foo = $conn->run(sub {
    return (2, 3, 5);
}), 'Do in array context';
is_deeply \@foo, [2, 3, 5], 'The return value should be the list';

ok @foo = $conn->run(sub {
    return wantarray ?  (2, 3, 5) : 'scalar';
}), 'Do in array context';
is_deeply \@foo, [2, 3, 5], 'Callback should know when its context is list';

# Test an exception.
eval {  $conn->run(sub { die 'WTF?' }) };
like $@, qr/WTF/, 'We should have died';

# Make sure nesting works okay.
ok !$conn->{_in_run}, '_in_run should be false';
$conn->run(sub {
    my $dbh = shift;
    ok $conn->{_in_run}, '_in_run should be set inside run()';
    local $dbh->{Active} = 0;
    $conn->run(sub {
        my $dbha = shift;
        isnt $dbha, $dbh, 'Nested should get the same when inactive';
        is $_, $dbha, 'Should have dbh in $_';
        is $conn->dbh, $dbha, 'Should get same dbh from dbh()';
        ok $conn->{_in_run}, '_in_run should be set inside nested run()';
    });
});
ok !$conn->{_in_run}, '_in_run should be false again';

# Make sure a nested txn call works, too.
ok ++$conn->{_depth}, 'Increase the transacation depth';
ok !($conn->{_dbh}{Active} = 0), 'Disconnect the handle';
$conn->run(sub {
    is shift, $conn->{_dbh},
        'The txn nested call to run() should get the deactivated handle';
    is $_, $conn->{_dbh}, 'Its should also be in $_';
});

# Make sure nesting works when ping returns false.
$conn->run(sub {
    my $dbh = shift;
    ok $conn->{_in_run}, '_in_run should be set inside run()';
    $dbh_ping_meth->replace( sub { 0 } );
    $conn->run(sub {
        is shift, $dbh, 'Nested get the same dbh even if ping is false';
        is $_, $dbh, 'Should have dbh in $_';
        is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
        ok $conn->{_in_run}, '_in_run should be set inside nested run()';
    });
});

# Test mode.
$conn->run(sub {
    is $conn->mode, 'no_ping', 'Default mode should be no_ping';
});

$conn->run(ping => sub {
    is $conn->mode, 'ping', 'Mode should be "ping" inside ping run'
});
is $conn->mode, 'no_ping', 'Back outside, should be "no_ping" again';

$conn->run(fixup => sub {
    is $conn->mode, 'fixup', 'Mode should be "fixup" inside fixup run'
});
is $conn->mode, 'no_ping', 'Back outside, should be "no_ping" again';

ok $conn->mode('ping'), 'Se mode to "ping"';
$conn->run(sub {
    is $conn->mode, 'ping', 'Mode should implicitly be "ping"'
});

ok $conn->mode('fixup'), 'Se mode to "fixup"';
$conn->run(sub {
    is $conn->mode, 'fixup', 'Mode should implicitly be "fixup"'
});

NOEXIT: {
    no warnings;

    # Make sure we don't exit the app via `next` or `last`.
    for my $mode (qw(ping no_ping fixup)) {
        $conn->mode($mode);
        ok !$conn->run(sub { next }), "Return via next should fail";
        ok !$conn->run(sub { last }), "Return via last should fail";
    }
}
