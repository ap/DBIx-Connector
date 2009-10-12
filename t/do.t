#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 42;
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

ok $conn->do(sub {
    ok shift->{AutoCommit}, 'Inside, we should not be in a transaction';
    ok $conn->{_in_do}, '_in_do should be true';
}), 'Do something with no cached handle';

# Test with cached dbh.
$module->unmock( '_connect');
ok my $dbh = $conn->dbh, 'Fetch the dbh';

# Set up a DBI mocker.
my $dbi_mock = Test::MockModule->new(ref $dbh, no_auto => 1);
my $ping = 1;
$dbi_mock->mock( ping => sub {
    return pass 'ping() should be called' if $ping;
    return fail 'ping() should not be called';
});

is $conn->{_dbh}, $dbh, 'The dbh should be cached';
ok $conn->connected, 'We should be connected';
ok $conn->do(sub {
    is shift, $dbh, 'The database handle should have been passed';
    is $_, $dbh, 'Should have dbh in $_';
    $ping = 0;
    is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
    $dbh->{Active} = 0;
    isnt $conn->dbh, $dbh, 'Should get different dbh if after disconnect';
    $ping = 1;
}), 'Do something with cached handle';

# Test the return value.
$dbh = $conn->dbh;
ok my $foo = $conn->do(sub {
    return (2, 3, 5);
}), 'Do in scalar context';
is $foo, 5, 'The return value should be the last value';

ok my @foo = $conn->do(sub {
    return (2, 3, 5);
}), 'Do in array context';
is_deeply \@foo, [2, 3, 5], 'The return value should be the list';

# Test an exception.
eval {  $conn->do(sub { die 'WTF?' }) };
ok $@, 'We should have died';

# Test a disconnect.
my $die = 1;
my $calls;
$conn->do(sub {
    my $dbha = shift;
    is shift, 'foo', 'Argument should have been passed';
    $calls++;
    if ($die) {
        is $_, $dbh, 'Should have dbh in $_';
        is $dbha, $dbh, 'Should have cached dbh';
        $ping = 0;
        is $conn->dbh, $dbh, 'Should get same dbh from dbh()';
        $ping = 1;
        $die = 0;
        $dbha->{Active} = 0;
        ok !$dbha->{Active}, 'Disconnect';
        die 'WTF?';
    }
    isnt $dbha, $dbh, 'Should have new dbh';
}, 'foo');

is $calls, 2, 'Sub should have been called twice';

# Check that args are passed.
$conn->do(sub {
    shift;
    is_deeply \@_, [qw(1 2 3)], 'Args should be passed through';
}, qw(1 2 3));

# Make sure nesting works okay.
ok !$conn->{_in_do}, '_in_do should be false';
$conn->do(sub {
    my $dbh = shift;
    ok $conn->{_in_do}, '_in_do should be set inside do()';
    local $dbh->{Active} = 0;
    $conn->do(sub {
        is shift, $dbh, 'Nested do should get the same dbh even if inactive';
        is $_, $dbh, 'Should have dbh in $_';
        isnt $conn->dbh, $dbh, 'Should not get same dbh from dbh()';
        ok $conn->{_in_do}, '_in_do should be set inside nested do()';
    });
});
ok !$conn->{_in_do}, '_in_do should be false again';

# Make sure a nested txn call works, too.
ok ++$conn->{_depth}, 'Increase the transacation depth';
ok !($conn->{_dbh}{Active} = 0), 'Disconnect the handle';
$conn->do(sub {
    is shift, $conn->{_dbh},
        'The txn nested call to do() should get the deactivated handle';
    is $_, $conn->{_dbh}, 'Its should also be in $_';
});
