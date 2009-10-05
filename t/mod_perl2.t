#!/usr/bin/env perl -w

use strict;
use warnings;
#use Test::More tests => 93;
use Test::More 'no_plan';

my $rcount = 1;
BEGIN {
    $ENV{MOD_PERL} = 1.31;
    $ENV{MOD_PERL_API_VERSION} = 2;

    package Apache2::ServerUtil;
    $INC{'Apache2/ServerUtil.pm'} = __FILE__;
    sub restart_count { $rcount }
}

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connector';
    use_ok $CLASS or die;
}

ok $rcount = 1, 'Set restart_count to 1';
ok my $conn1 = $CLASS->new( 'dbi:ExampleP:dummy' ), 'Get connection';
ok my $conn2 = $CLASS->new( 'dbi:ExampleP:dummy' ), 'Get connection again';
isnt $conn2, $conn1, 'It should not be the same object';

ok $rcount = 2, 'Set restart_count to something else';
ok $conn2 = $CLASS->new( 'dbi:ExampleP:dummy' ), 'Get with same args';
isnt $conn2, $conn1, 'It still should not be the same object';

ok $conn1 = $CLASS->new( 'dbi:ExampleP:dummy' ), 'Get conn one more time';
is $conn1, $conn2, 'Now it should be the cached object';
