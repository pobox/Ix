use 5.20.0;
package Ix::Result;

use Moose::Role;
use experimental qw(signatures postderef);

use namespace::autoclean;

requires 'result_type';
requires 'result_arguments';

package Ix::Result::Generic {

  use Moose;
  use MooseX::StrictConstructor;
  use experimental qw(signatures postderef);

  use namespace::autoclean;

  has result_type => (is => 'ro', isa => 'Str', required => 1);
  has result_arguments => (
    is  => 'ro',
    isa => 'HashRef',
    required => 1,
  );

  with 'Ix::Result';
};

package Ix::Result::FoosSet {

  use Moose;
  use MooseX::StrictConstructor;
  use experimental qw(signatures postderef);

  use namespace::autoclean;

  has accountId   => (is => 'ro', isa => 'Str', required => 1);

  has result_type => (is => 'ro', isa => 'Str', required => 1);

  has result_arguments => (
    is => 'ro',
    lazy => 1,
    default => sub ($self) {
      my %prop = (
        accountId => $self->accountId,
        oldState => $self->old_state,
        newState => $self->new_state,

        # 1. probably we should map the values here through a packer
        # 2. do we need to include empty ones?  spec is silent
        created   => $self->created,
        updated   => $self->updated,
        destroyed => $self->destroyed,
      );

      for my $p (qw(created updated destroyed)) {
        my $m = "not_$p";
        my $errors = $self->$m;

        $prop{"not\u$p"} = {
          map {; $_ => $errors->{$_}->result_arguments } keys $errors->%*
        };
      }

      return \%prop;
    },
  );

  has old_state => (is => 'ro');
  has new_state => (is => 'ro');

  has created => (is => 'ro');
  has updated => (is => 'ro');
  has destroyed => (is => 'ro');

  has not_created => (is => 'ro');
  has not_updated => (is => 'ro');
  has not_destroyed => (is => 'ro');

  with 'Ix::Result';
};

1;
