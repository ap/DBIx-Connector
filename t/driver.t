#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 17;
#use Test::More 'no_plan';

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connector::Driver';
    use_ok $CLASS or die;
    use_ok 'DBIx::Connector' or die;
    use_ok "$CLASS\::Pg" or die;
}

# Make sure it's a singleton.
ok my $dr = $CLASS->new( 'ExampleP'), 'Create a new driver';
isa_ok $dr, $CLASS;
is $CLASS->new('ExampleP'), $dr, 'It should be a singleton';

# Subclass should have a different singleton.
ok my $pg = "$CLASS\::Pg"->new( 'Pg' ), 'Get a Pg driver';
isa_ok $pg, "$CLASS\::Pg";
isa_ok $pg, $CLASS;
isnt $pg, $dr, 'It should be a different object';
is "$CLASS\::Pg"->new('Pg'), $pg, 'But it should be a singleton';
is $CLASS->new('Pg'), $pg, 'And it should be returned from the factory constructor';

ok my $conn = DBIx::Connector->new( 'dbi:ExampleP:dummy', '', '' ),
    'Construct example connection';
is $conn->driver, $dr, 'It should have the driver';

ok $conn = DBIx::Connector->new('dbi:Pg:dbname=try', '', '' ),
    'Construct a Pg connection';
isa_ok $conn->driver, 'DBIx::Connector::Driver::Pg';
is $conn->driver, $pg, 'It should be the Pg singleton';
