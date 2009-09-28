#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 18;
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
$module->mock( _connect => '_connect');
ok $conn->do(sub {
    is shift, '_connect', '_connect should have been called';
}), 'Do something with no cached handle';

# Test with cached dbh.
$module->unmock( '_connect');
ok my $dbh = $conn->dbh, 'Fetch the dbh';
is $conn->{_dbh}, $dbh, 'The dbh should be cached';
ok $conn->connected, 'We should be connected';
ok $conn->do(sub {
    is shift, $dbh, 'The database handle should have been passed';
}), 'Do something with cached handle';

# Test the return value.
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

is $calls, 2, 'Sub should have been called twice';

# XXX Test extra arguments.

