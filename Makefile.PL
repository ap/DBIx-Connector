use 5.008001; use strict; use warnings;

my $sc = q<https://github.com/ap/DBIx-Connector>;
my $bt = q<https://github.com/ap/DBIx-Connector/issues>;

our %META = (
	name        => 'DBIx-Connector',
	author      => 'David E. Wheeler',
	x_copyright => { holder => 'David E. Wheeler', year => 2016 },
	license     => 'perl_5',
	resources   => {
		license    => [ q<https://dev.perl.org/licenses/> ],
		repository => { type => 'git', url => "$sc.git", web => $sc },
		bugtracker => { web => $bt },
	},
	dynamic_config => 0,
	prereqs => {
		runtime => {
			requires => {qw(
				perl 5.008001
				DBI 1.605
			)},
			recommends => {qw(
				DBI 1.614
			)},
		},
		test => {
			requires => {qw(
				Test::More 0
			)},
		},
	},
);

require './inc/WriteMakefile.pl';
