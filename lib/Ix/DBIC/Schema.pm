use 5.20.0;
use warnings;
package Ix::DBIC::Schema;

use parent 'DBIx::Class';
use Scalar::Util qw(blessed);
use experimental qw(signatures postderef);

sub ix_finalize ($self) {
  my $source_reg = $self->source_registrations;
  for my $moniker (keys %$source_reg) {
    my $rclass = $source_reg->{$moniker}->result_class;
    $rclass->ix_finalize if $rclass->can('ix_finalize');
  }
}

# Taken from https://wiki.postgresql.org/wiki/Skip32, with one major
# modification: Only positive numbers in the range of 0 to (2^32)-1) are
# allowed as input/output, instead of -(2^31) to (2^31)-1).
#
# In order for this to work, we treat any number over (2^31)-1) as negative,
# subtracting (2^31)-1) from it before multiplying it by -1.
#
# That is, 2^31 (2147483648) is -1, (2^31)+1 (2147483649) is -2, and so on.
my $FN = <<'END_SQL';
CREATE OR REPLACE FUNCTION ix_skip32(val bigint, cr_key bytea, encrypt bool) returns bigint
AS $$
DECLARE
  kstep int;
  k int;
  wl int4;
  wr int4;
  g1 int4;
  g2 int4;
  g3 int4;
  g4 int4;
  g5 int4;
  g6 int4;
  ret bigint;
  ftable bytea:='\xa3d70983f848f6f4b321157899b1aff9e72d4d8ace4cca2e5295d91e4e3844280adf02a017f1606812b77ac3e9fa3d5396846bbaf2639a197caee5f5f7166aa239b67b0fc193811beeb41aead0912fb855b9da853f41bfe05a58805f660bd89035d5c0a733066569450094566d989b7697fcb2c2b0fedb20e1ebd6e4dd474a1d42ed9e6e493ccd4327d207d4dec7671889cb301f8dc68faac874dcc95d5c31a47088612c9f0d2b8750825464267d0340344b1c73d1c4fd3bccfb7fabe63e5ba5ad04239c145122f02979717eff8c0ee20cefbc72756f37a1ecd38e628b8610e8087711be924f24c532369dcff3a6bbac5e6ca9135725b5e3bda83a0105592a46';
BEGIN
  IF (octet_length(cr_key)!=10) THEN
    RAISE EXCEPTION 'The encryption key must be exactly 10 bytes long.';
  END IF;

  IF (val > (2^32)-1 OR val < 0) THEN
    RAISE EXCEPTION 'We can only handle values in the range 0 - (2^32)-1';
  END IF;

  IF (encrypt) THEN
    kstep := 1;
    k := 0;
  ELSE
    kstep := -1;
    k := 23;
  END IF;

  IF (val > (2^31)-1) THEN
    -- skip32 is supposed to be dealing with a signed 32 bit integer, but
    -- we've changed it to only deal in positive values. To make this work
    -- we must translate any values over the max positive value ((2^31)-1)
    -- into their negative counterparts
    -- 2^31   becomes -1
    -- 2^31+1 becomes -2, etc...

    val := val - (2^31-1);
    val := val * -1;
  END IF;

  wl := (val & -65536) >> 16;
  wr := val & 65535;

  FOR i IN 0..11 LOOP
    g1 := (wl>>8) & 255;
    g2 := wl & 255;
    g3 := get_byte(ftable, g2 # get_byte(cr_key, (4*k)%10)) # g1;
    g4 := get_byte(ftable, g3 # get_byte(cr_key, (4*k+1)%10)) # g2;
    g5 := get_byte(ftable, g4 # get_byte(cr_key, (4*k+2)%10)) # g3;
    g6 := get_byte(ftable, g5 # get_byte(cr_key, (4*k+3)%10)) # g4;
    wr := wr # (((g5<<8) + g6) # k);
    k := k + kstep;

    g1 := (wr>>8) & 255;
    g2 := wr & 255;
    g3 := get_byte(ftable, g2 # get_byte(cr_key, (4*k)%10)) # g1;
    g4 := get_byte(ftable, g3 # get_byte(cr_key, (4*k+1)%10)) # g2;
    g5 := get_byte(ftable, g4 # get_byte(cr_key, (4*k+2)%10)) # g3;
    g6 := get_byte(ftable, g5 # get_byte(cr_key, (4*k+3)%10)) # g4;
    wl := wl # (((g5<<8) + g6) # k);
    k := k + kstep;
  END LOOP;

  ret = (wr << 16) | (wl & 65535);

  if (ret < 0) THEN
    -- Like on input, we only want consumers to see positive values, so
    -- we must translate negative values to their positive counterparts
    -- -1 becomes 2^31
    -- -2 becomes 2^31+1, etc...
    ret := ret * -1;
    ret := ret + (2^31-1); 
  END IF;

  RETURN ret;
END
$$ immutable strict language plpgsql;
END_SQL

# We'll fill in a secret for this install the first time we deploy
# that it will use from then on
my $FN_WRAPPER = <<'END_SQL';
CREATE OR REPLACE FUNCTION ix_skip32_secret(val bigint, encrypt bool) returns bigint
AS $$
DECLARE
  secret bytea:='\x%s';
BEGIN
  RETURN ix_skip32(val, secret, encrypt);
END
$$ immutable strict language plpgsql; 
END_SQL

# An easy way to get a new accountId
my $ACID_FUNC = <<'END_SQL';
CREATE OR REPLACE FUNCTION ix_new_account_id() returns bigint
AS $$
BEGIN
  RETURN ix_skip32_secret(nextval('account_id_seed_seq'), true);
END
$$ immutable strict language plpgsql;
END_SQL

sub ix_schema_version { "1" }

my $CONFIG_TABLE = <<'END_SQL';
CREATE TABLE ix_config (
  ix_schema_version    text,
  local_schema_version text,
  ix_skip32_secret     bytea,
  ix_skip32_secret_hex text
);
END_SQL

my $CONFIG_INSERT = <<'END_SQL';
INSERT INTO ix_config VALUES (
  ?, ?, ?, ?
);
END_SQL

sub deploy {
  my ($self) = shift;

  unless ($self->can('local_schema_version')) {
    my $class = blessed($self);
    die "Unable to deploy: $class must define a local_schema_version sub\n";
  }

  # 10 random bytes as hex
  my $secret = join '', map {
    sprintf("%02x", $_)
  } map {
    int(rand(256))
  } 1..10;

  $self->storage->dbh_do(sub {
    my ($storage, $dbh) = @_;
    $dbh->do($FN);

    $dbh->do(sprintf($FN_WRAPPER, $secret));
    $dbh->do('CREATE SEQUENCE "account_id_seed_seq";');
    $dbh->do($ACID_FUNC);

    for my $source_name ($self->sources) {
      my $source = $self->source($source_name);
      if ($source->has_column('modSeqCreated')) {
        my $table = $source->name;

        $dbh->do("CREATE SEQUENCE ${table}_seed_seq");
      }
    }

    $dbh->do($CONFIG_TABLE);
    $dbh->do($CONFIG_INSERT, {},
      $self->ix_schema_version,
      $self->local_schema_version,
      '\x' . $secret,
      uc $secret,
    );
  });
  $self->DBIx::Class::Schema::deploy(@_)
}

sub ix_config {
  my ($self) = shift;

  return $self->storage->dbh_do(sub {
    my ($storage, $dbh) = @_;

    return $dbh->selectrow_hashref('SELECT * FROM ix_config');
  });
}

1;
