#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More tests => 81;
#use Test::More 'no_plan';
use Test::MockModule;

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connector';
    use_ok $CLASS or die;
    $ENV{DBICONNTEST} = 1;
}

ok my $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ),
    'Construct connector';

eval { $conn->with };
ok my $err = $@, 'Should get an error';
like $err, qr/Missing required mode argument/,
    'It should be the missing mode error';

eval { $conn->with('foo') };
ok $err = $@, 'Should get an error';
like $err, qr/Invalid mode: "foo"/, 'It should be the invalid mode error';

my $mocker = Test::MockModule->new($CLASS);
for my $mode qw(fixup ping no_ping) {
    ok my $proxy = $conn->with( $mode ), "Create a $mode proxy";
    isa_ok $proxy, 'DBIx::Connector::Proxy', "The $mode proxy";
    is $proxy->conn, $conn, "$mode proxy should have stored the connector";
    is $proxy->mode, $mode, "$mode proxy should have stored the mode";

    for my $meth qw(run txn svp) {
        $mocker->mock($meth => sub {
            is shift, $conn, "... Proxy $meth call should dispatch to conn $meth";
            is shift, $mode, "... Mode $meth should have been passed to $meth";
        });
        is $proxy->dbh, $conn->dbh, '... Should get the connection dbh';
        ok $proxy->$meth( sub { } ), "Call $meth";
        ok $conn->with($mode)->$meth( sub { } ), "Call $meth on new proxy";
    }
}


