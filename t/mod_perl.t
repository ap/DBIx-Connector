#!/usr/bin/env perl -w

use strict;
use warnings;
#use Test::More tests => 93;
use Test::More 'no_plan';

BEGIN {
    $ENV{MOD_PERL} = 1.31;
}

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connector';
    use_ok $CLASS or die;
}

ok $Apache::ServerStarting = 1, 'Set Apache::ServerStarting to 1';
ok my $conn1 = $CLASS->new( 'dbi:ExampleP:dummy' ), 'Get connection';
ok my $conn2 = $CLASS->new( 'dbi:ExampleP:dummy' ), 'Get connection again';
isnt $conn2, $conn1, 'It should not be the same object';

ok !($Apache::ServerStarting = 0), 'Set Apache::ServerStarting to false';
ok $conn2 = $CLASS->new( 'dbi:ExampleP:dummy' ), 'Get with same args';
isnt $conn2, $conn1, 'It still should not be the same object';

ok $conn1 = $CLASS->new( 'dbi:ExampleP:dummy' ), 'Get conn one more time';
is $conn1, $conn2, 'Now it should be the cached object';


