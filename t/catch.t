#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 14;
#use Test::More 'no_plan';
use Test::MockModule;

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connector';
    use_ok $CLASS or die;
}

ok my $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ), 'Construct connector';

sub run_inner {
    shift->run(sub {
        die 'WTF!';
    }, catch => sub {
        die 'run_inner said: '. $_;
    });
}

sub run_outer {
    shift->run(sub {
        run_inner( $conn );
    }, catch => sub {
        die 'run_outer said: '. $_;
    });
}

sub txn_inner {
    shift->txn(sub {
        die 'WTF!';
    }, catch => sub {
        die 'txn_inner said: '. $_;
    });
}

sub txn_outer {
    shift->txn(sub {
        txn_inner( $conn );
    }, catch => sub {
        die 'txn_outer said: '. $_;
    });
}

my $driver = Test::MockModule->new("$CLASS\::Driver");

# Mock the savepoint driver methods.
$driver->mock( $_ => sub { shift } ) for qw(savepoint release rollback_to);

sub svp_inner {
    shift->svp(sub {
        die 'WTF!';
    }, catch => sub {
        die 'svp_inner said: '. $_;
    });
}

sub svp_outer {
    shift->svp(sub {
        svp_inner( $conn );
    }, catch => sub {
        die 'svp_outer said: '. $_;
    });
}

foreach my $mode (qw/ping no_ping fixup/) {
    ok $conn->mode( $mode ), qq{Set mode to "$mode"};
    local $@;
    eval { run_outer($conn); };
    like $@, qr{run_outer said: run_inner said: WTF!}, "$mode run should handle nesting";
    eval { txn_outer($conn); };
    like $@, qr{txn_outer said: txn_inner said: WTF!}, "$mode txn should handle nesting";
    eval { svp_outer($conn); };
    like $@, qr{svp_outer said: svp_inner said: Savepoint aborted: WTF!},
        "$mode svp should handle nesting";
}

