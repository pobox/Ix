use 5.20.0;

package Ix::Result::Masked;
use Moose;

use experimental qw(signatures postderef);

use overload fallback => 1, '""' => \&maybe_mask_value;

our $MASKING = 0;

sub on { $MASKING = 1; }
sub off { $MASKING = 0; }

has value => (
  is => 'ro',
);

sub maybe_mask_value ($self, @) {
  return $MASKING ? '***MASKED***' : $self->value;
}

sub TO_JSON ($self, @) {
  return "$self";
}

1;

