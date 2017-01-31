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

    if ($rclass->can('array_class')) {
      my $ac = $rclass->array_class;
      $self->register_class(%$ac);
    }
  }
}

# This code lifted from https://wiki.postgresql.org/wiki/Pseudo_encrypt which
# credits it as follows: The first iteration of this code was posted in
# http://archives.postgresql.org/pgsql-general/2009-05/msg00082.php by Daniel
# Vérité; below is an improved version, following comments by Jaka Jancar.
#
# This specific algorithm is not important, nor (at least for now) are the
# invertability of a Feistel network.  It's just a quick way to get fast
# non-sequential integers as identifiers.  We can replace it in the future, if
# we have a preferred mechanism (like uuids, if we switch to 128b keys), but
# without this, we had tests relying on ids being in sequence, which was no
# good.
#
# If we *do* stick with this, we should pick the constants at deploy time and
# store them in the database.
my $FN = <<'END_SQL';
CREATE OR REPLACE FUNCTION pseudo_encrypt(VALUE int) returns int AS $$
DECLARE
l1 int;
l2 int;
r1 int;
r2 int;
i int:=0;
BEGIN
 l1:= (VALUE >> 16) & 65535;
 r1:= VALUE & 65535;
 WHILE i < 3 LOOP
   l2 := r1;
   r2 := l1 # ((((1366 * r1 + 150889) % 867530) / 867530.0) * 32767)::int;
   l1 := l2;
   r1 := r2;
   i := i + 1;
 END LOOP;
 RETURN ((r1 << 16) + l1);
END;
$$ LANGUAGE plpgsql strict immutable;
END_SQL

sub deploy {
  my ($self) = shift;
  $self->storage->dbh_do(sub {
    my ($storage, $dbh) = @_;
    $dbh->do("CREATE SEQUENCE key_seed_seq;");
    $dbh->do($FN);
  });
  $self->DBIx::Class::Schema::deploy(@_)
}

1;
