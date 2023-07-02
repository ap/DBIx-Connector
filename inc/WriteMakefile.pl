use strict; use warnings;

require ExtUtils::MakeMaker;

defined(our $distlib) or ($distlib = -d 'lib' ? 'lib' : '.');
defined(our $manifest_cmd) or ($manifest_cmd = "git ls-files ':!README.pod'");

sub MY::postamble { -f 'META.yml' ? return : <<"" }
create_distdir : MANIFEST
distdir        : MANIFEST
MANIFEST :
	( $manifest_cmd ; echo MANIFEST ) > MANIFEST
distdir : boilerplate
.PHONY  : boilerplate
boilerplate : distmeta
	\$(PERL) -I$distlib inc/boilerplate.pl \$(DISTVNAME)

our (%META, %MM_ARGS);

# have to do this since old EUMM dev releases miss the eval $VERSION line
my $eumm_version  = eval $ExtUtils::MakeMaker::VERSION;
my $mymeta        = $eumm_version >= 6.57_02;
my $mymeta_broken = $mymeta && $eumm_version < 6.57_07;

(my $basepath = "$distlib/$META{name}") =~ s{-}{/}g;

($MM_ARGS{NAME} = $META{name}) =~ s/-/::/g;
$MM_ARGS{VERSION_FROM} = "$basepath.pm";
$MM_ARGS{ABSTRACT_FROM} = -f "$basepath.pod" ? "$basepath.pod" : "$basepath.pm";
$META{license} = [ $META{license} ]
	if $META{license} && !ref $META{license};
$MM_ARGS{LICENSE} = $META{license}[0]
	if $META{license} && $eumm_version >= 6.30;
$MM_ARGS{NO_MYMETA} = 1
	if $mymeta_broken;
$MM_ARGS{META_ADD} = { 'meta-spec' => { version => 2 }, %META }
	unless -f 'META.yml';
$MM_ARGS{PL_FILES} ||= {};
$MM_ARGS{NORECURS} = 1
	if not exists $MM_ARGS{NORECURS};

for (qw(configure build test runtime)) {
	my $key = $_ eq 'runtime' ? 'PREREQ_PM' : uc $_.'_REQUIRES';
	my $r = $MM_ARGS{$key} = {
		%{$META{prereqs}{$_}{requires} || {}},
		%{delete $MM_ARGS{$key} || {}},
	};
	defined $r->{$_} or delete $r->{$_} for keys %$r;
}

$MM_ARGS{MIN_PERL_VERSION} = eval delete $MM_ARGS{PREREQ_PM}{perl} || 0;

delete $MM_ARGS{MIN_PERL_VERSION}
	if $eumm_version < 6.47_01;
$MM_ARGS{BUILD_REQUIRES} = {%{$MM_ARGS{BUILD_REQUIRES}}, %{delete $MM_ARGS{TEST_REQUIRES}}}
	if $eumm_version < 6.63_03;
$MM_ARGS{PREREQ_PM} = {%{$MM_ARGS{PREREQ_PM}}, %{delete $MM_ARGS{BUILD_REQUIRES}}}
	if $eumm_version < 6.55_01;
delete $MM_ARGS{CONFIGURE_REQUIRES}
	if $eumm_version < 6.51_03;

ExtUtils::MakeMaker::WriteMakefile(%MM_ARGS);
