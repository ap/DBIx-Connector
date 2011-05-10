#!/usr/bin/perl -w

use strict;
use warnings;
use Test::More tests => 8;
#use Test::More 'no_plan';

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connector';
    use_ok $CLASS or die;
}

ok my $conn = $CLASS->new( 'dbi:ExampleP:dummy', '', '' ), 'Construct connector';

sub inner {
    shift->run(sub {
        die 'WTF!';
    }, catch => sub {
        die 'inner said: '. $_;
    });
}

sub outer {
    shift->run(sub {
        inner( $conn );
    }, catch => sub {
        die 'outer said: '. $_;
    });
}

foreach my $mode (qw/ping no_ping fixup/) {
    ok $conn->mode( $mode ), qq{Set mode to "$mode"};
    local $@;
    eval { outer($conn); };
    like $@, qr{outer said: inner said: WTF!}, "$mode mode should handle nesting";
}

