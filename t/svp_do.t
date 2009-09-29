#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 2;
#use Test::More 'no_plan';

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connection';
    use_ok $CLASS or die;
}

ok my $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ),
    'Get a connection';

