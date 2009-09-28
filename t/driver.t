#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 16;
#use Test::More 'no_plan';

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connection::Driver';
    use_ok $CLASS or die;
    use_ok 'DBIx::Connection' or die;
    use_ok "$CLASS\::Pg" or die;
}

# Make sure it's a singleton.
ok my $dr = $CLASS->new, 'Create a new driver';
isa_ok $dr, $CLASS;
is $CLASS->new, $dr, 'It should be a singleton';

# Subclass should have a different singleton.
ok my $pg = "$CLASS\::Pg"->new, 'Get a Pg driver';
isa_ok $pg, "$CLASS\::Pg";
isa_ok $pg, $CLASS;
isnt $pg, $dr, 'It should be a different object';
is "$CLASS\::Pg"->new, $pg, 'But it should be a singleton';

ok my $conn = DBIx::Connection->new( 'dbi:ExampleP:dummy', '', '' ),
    'Construct example connection';
is $conn->_set_driver, $dr, 'It should have the driver';

ok $conn = DBIx::Connection->new('dbi:Pg:dbname=try', '', '' ),
    'Construct a Pg connection';
isa_ok $conn->_set_driver, 'DBIx::Connection::Driver::Pg';
is $conn->{_driver}, $pg, 'It should be the Pg singleton';
