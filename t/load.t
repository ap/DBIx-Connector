#!/usr/bin/env perl

use strict;
use warnings;
use Test::More tests => 2;

my $CLASS;
BEGIN {
    $CLASS = 'DBIx::Connection';
    use_ok $CLASS or die;
}

can_ok $CLASS, qw(
    new
    connect_args
    dbh
    connected
    connect
    disconnect
    DESTROY
    do
);

