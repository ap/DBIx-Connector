use strict; use warnings;

use Test::More;
use File::Find;
use File::Spec::Functions qw(catdir splitdir);

BEGIN { # compat shim for old Test::More
    defined &BAIL_OUT or *BAIL_OUT = sub {
        my $t = Test::Builder->new;
        $t->no_ending(1); # needed before Test::Builder 0.61
        $t->BAILOUT(@_); # added in Test::Builder 0.40
    };
}

my $CLASS = 'DBIx::Connector';
my @drivers;
find {
    no_chdir => 1,
    wanted   => sub {
        s/[.]pm$// or return;
        my (undef, @path_segment) = splitdir $_; # throw away initial lib/ segment
        push @drivers, join '::', @path_segment;
    }
}, catdir qw(lib DBIx Connector Driver);

plan tests => (@drivers * 3) + 3;

# Test the main class.
use_ok $CLASS or BAIL_OUT "Could not load $CLASS";
can_ok $CLASS, qw(
    new
    dbh
    connect
    connected
    disconnect
    DESTROY
);

# Test the drivers.
use_ok "$CLASS\::Driver";
for my $driver (@drivers) {
    use_ok $driver or $driver ne "$CLASS\::Driver" or BAIL_OUT "Could not load $driver";
    ok eval { $driver->isa( $_ ) }, "'$driver' isa '$_'" for "$CLASS\::Driver";
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
