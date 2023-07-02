use strict; use warnings;

use Test::More;
use File::Find;
use File::Spec::Functions qw(catdir splitdir);

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
use_ok $CLASS or die;
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
    use_ok $driver;
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
