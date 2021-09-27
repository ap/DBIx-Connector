use strict; use warnings;

use Test::More tests => 49;
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

ok $conn->run( fixup => sub {
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

is $conn->{_dbh}, $dbh, 'The dbh should be stored';
is $ping, 0, 'No pings yet';
ok $conn->connected, 'We should be connected';
is $ping, 1, 'Ping should have been called';
ok $conn->run( fixup => sub {
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
ok my $foo = $conn->run( fixup => sub {
    return (2, 3, 5);
}), 'Do in scalar context';
is $foo, 5, 'The return value should be the last value';

ok my @foo = $conn->run( fixup => sub {
    return (2, 3, 5);
}), 'Do in array context';
is_deeply \@foo, [2, 3, 5], 'The return value should be the list';

# Test an exception.
eval {  $conn->run( fixup => sub { die 'WTF?' }) };
like $@, qr/WTF/, 'We should have died';

# Test a disconnect.
my $die = 1;
my $calls;
$conn->run( fixup => sub {
    my $dbha = shift;
    ok $conn->{_in_run}, '_in_run should be true';
    $calls++;
    if ($die) {
        is $_, $dbh, 'Should have dbh in $_';
        is $dbha, $dbh, 'Should have stored dbh';
        $ping = 0;
        is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
        is $ping, 0, 'Should have been no ping';
        $die = 0;
        $dbha->{Active} = 0;
        ok !$dbha->{Active}, 'Disconnect';
        die 'WTF?';
    }
    isnt $dbha, $dbh, 'Should have new dbh';
});

is $calls, 2, 'Sub should have been called twice';

# Make sure nesting works okay.
ok !$conn->{_in_run}, '_in_run should be false';
$conn->run( fixup => sub {
    my $dbh = shift;
    ok $conn->{_in_run}, '_in_run should be set inside run( fixup => )';
    local $dbh->{Active} = 0;
    $conn->run( fixup => sub {
        my $dbha = shift;
        isnt $dbha, $dbh, 'Nested should get the same when inactive';
        is $_, $dbha, 'Should have dbh in $_';
        is $conn->dbh, $dbha, 'Should get same dbh from dbh()';
        ok $conn->{_in_run}, '_in_run should be set inside nested run( fixup => )';
    });
});
ok !$conn->{_in_run}, '_in_run should be false again';

# Make sure a nested txn call works, too.
ok ++$conn->{_depth}, 'Increase the transacation depth';
ok !($conn->{_dbh}{Active} = 0), 'Disconnect the handle';
$conn->run( fixup => sub {
    is shift, $conn->{_dbh},
        'The txn nested call to run( fixup => ) should get the deactivated handle';
    is $_, $conn->{_dbh}, 'Its should also be in $_';
});

# Make sure nesting works when ping returns false.
$conn->run( fixup => sub {
    my $dbh = shift;
    ok $conn->{_in_run}, '_in_run should be set inside run( fixup => )';
    $dbh_ping_meth->replace( sub { 0 } );
    $conn->run( fixup => sub {
        is shift, $dbh, 'Nested get the same dbh even if ping is false';
        is $_, $dbh, 'Should have dbh in $_';
        is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
        ok $conn->{_in_run}, '_in_run should be set inside nested run( fixup => )';
    });
});
