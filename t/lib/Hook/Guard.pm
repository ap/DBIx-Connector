use strict; use warnings;

package Hook::Guard;

sub new {
	my ( $class, $glob ) = ( shift, @_ );
	local $@;
	my $code = eval { *$glob{'CODE'} }
		or die sprintf "Cannot hook a %s at %s line %d.\n", (
			( $@ ? 'non-glob' : 'glob with an empty CODE slot' ),
			( caller )[1,2],
		);
	bless [ $glob, $code ], $class;
}

sub glob     { $_[0][0] }
sub original { $_[0][1] }

sub current  { *{ shift->glob }{'CODE'} }

sub replace { my $self = shift; no warnings 'redefine'; *{ $self->glob } = \&{ $_[0] };     $self }
sub restore { my $self = shift; no warnings 'redefine'; *{ $self->glob } = $self->original; $self }

sub prepend {
	my $self = shift;
	my $combined = do { # new pad to avoid capturing $self
		my $sub = shift;
		my $current = $self->current;
		sub { $sub->( @_ ); &$current };
	};
	$self->replace( $combined );
}

sub DESTROY { shift->restore }

1;
