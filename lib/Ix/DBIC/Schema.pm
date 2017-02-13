use 5.20.0;
use warnings;
package Ix::DBIC::Schema;

use parent 'DBIx::Class';

use experimental qw(signatures postderef);

sub ix_finalize ($self) {
	my $source_reg = $self->source_registrations;
  for my $moniker (keys %$source_reg) {
    my $rclass = $source_reg->{$moniker}->result_class;
    $rclass->ix_finalize if $rclass->can('ix_finalize');
  }
}

sub deploy {
  my ($self) = shift;
  $self->storage->dbh_do(sub {
    my ($storage, $dbh) = @_;

    # Leaving this here in case we want to add anything
    # -- alh, 2017-01-12
  });
  $self->DBIx::Class::Schema::deploy(@_)
}

1;
