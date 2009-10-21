#!/usr/bin/env perl -w

use strict;
use warnings;
use Test::More;
use File::Find;
use File::Spec::Functions qw(catdir splitdir);

my $CLASS;
my @drivers;
BEGIN {
    $CLASS = 'DBIx::Connector';
    my $dir = catdir qw(lib DBIx Connector Driver);
    find {
        no_chdir => 1,
        wanted   => sub {
            s/[.]pm$// or return;
            s{^$dir/?}{};
            push @drivers, "$CLASS\::Driver::" . join( '::', splitdir $_);
        }
    }, $dir;
}

plan tests => (@drivers * 3) + 3;

# Test the main class.
use_ok $CLASS or die;
can_ok $CLASS, qw(
    new
    dbh
    connect
    connected
    disconnect
    DESTROY
    do
    txn_do
    svp_do
);

# Test the drivers.
use_ok "$CLASS\::Driver";
for my $driver (@drivers) {
    use_ok $driver;
    isa_ok $driver, "$CLASS\::Driver", $driver;
    can_ok $driver, qw(
        new
        ping
        begin_work
        commit
        rollback
        savepoint
        release
        rollback_to
    );
}
