use strict; use warnings;

use Test::More tests => 14;
use DBIx::Connector;
use DBIx::Connector::Driver::Pg;

# Make sure it's a singleton.
ok my $dr = DBIx::Connector::Driver->new( 'ExampleP' ), 'Create a new driver';
isa_ok $dr, 'DBIx::Connector::Driver';
is +DBIx::Connector::Driver->new( 'ExampleP' ), $dr, 'It should be a singleton';

# Subclass should have a different singleton.
ok my $pg = DBIx::Connector::Driver::Pg->new( 'Pg' ), 'Get a Pg driver';
isa_ok $pg, 'DBIx::Connector::Driver::Pg';
isa_ok $pg, 'DBIx::Connector::Driver';
isnt $pg, $dr, 'It should be a different object';
is +DBIx::Connector::Driver::Pg->new( 'Pg' ), $pg, 'But it should be a singleton';
is +DBIx::Connector::Driver->new( 'Pg' ), $pg, 'And it should be returned from the factory constructor';

ok my $conn = DBIx::Connector->new( 'dbi:ExampleP:dummy', '', '' ),
    'Construct example connection';
is $conn->driver, $dr, 'It should have the driver';

ok $conn = DBIx::Connector->new( 'dbi:Pg:dbname=try', '', '' ),
    'Construct a Pg connection';
isa_ok $conn->driver, 'DBIx::Connector::Driver::Pg';
is $conn->driver, $pg, 'It should be the Pg singleton';
