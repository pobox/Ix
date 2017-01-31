use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use JSON;
use Test::Deep;
use Test::Deep::JType;
use Test::More;
use Try::Tiny;

my ($app, $jmap_tester) = Bakesale::Test->new_test_app_and_tester;
\my %account = Bakesale::Test->load_trivial_account($app->processor->schema_connection);

sub try_sql ($sql) {
  return try {
    $app->processor->schema_connection->storage->dbh_do(
      sub {
        my ($storage, $dbh) = @_;

        return $dbh->selectall_arrayref($sql)->[0][0];
      }
    );
  } catch {
    my $err = $_;
    return (undef, $err);
  };
}

sub skip32 ($val, $encrypt) {
  my $got;

  $app->processor->schema_connection->storage->dbh_do(
    sub {
      my ($storage, $dbh) = @_;

      $got = $dbh->selectall_arrayref(
        "SELECT ix_skip32(?, 'nooneknows'::bytea, ?)", {}, $val, $encrypt
      );
    }
  );

  return $got->[0][0];
}

sub transform ($val) {
  return $val if $val >= 0;

  # Same thing the sql is doing
  $val *= -1;
  $val += (2**31)-1;
  return $val;
}

# Table from https://wiki.postgresql.org/wiki/Skip32, but negative numbers
# converted to positive over 2^32-1
for my $test (
  [  2**31+9,  -487745093 ], # -10
  [  2**31+8, -2112342827 ], # ...
  [  2**31+7,  1303049886 ],
  [  2**31+6, -1084841580 ],
  [  2**31+5,   560956799 ],
  [  2**31+4,    82237967 ],
  [  2**31+3,   425659720 ],
  [  2**31+2, -2105383591 ],
  [  2**31+1, -1511018704 ],
  [  2**31,   -1020536589 ], # -1
  [  0,        1500550465 ],
  [  1,        1203450477 ],
  [  2,        1404417409 ],
  [  3,        2642533342 ],
  [  4,        4088017046 ],
  [  5,        2268925339 ],
  [  6,        1957824249 ],
  [  7,        3824804210 ],
  [  8,          21505071 ],
  [  9,        4015394386 ],
  [ 10,        3424704264 ],
) {
  my ($orig, $expect) = @$test;

  if ($expect < 0) {
    $expect = transform($expect);
  }

  is(
    skip32($orig, 1),
    $expect,
    "skip32 encrypting of $orig is correct ($expect)"
  );

  is(
    skip32($expect, 0),
    $orig,
    "skip32 decrypting of $expect is correct ($orig)"
  );
}

{
  # Test our limits
  my $too_high = 2**32;
  my ($ok, $err) = try_sql(
    "SELECT ix_skip32($too_high, 'nooneknows'::bytea, true)"
  );
  ok(!$ok, 'ix_skip32 with 2^32 failed');
  like($err, qr/We can only handle values in the range/, 'correct error');

  my $too_low = -1;
  ($ok, $err) = try_sql(
    "SELECT ix_skip32($too_low, 'nooneknows'::bytea, true)"
  );
  ok(!$ok, 'ix_skip32 with -1 failed');
  like($err, qr/We can only handle values in the range/, 'correct error');

  # Maximum number is equivalent to -2147483648
  my $upper_lim = (2**32)-1;
  ($ok, $err) = try_sql(
    "SELECT ix_skip32($upper_lim, 'nooneknows'::bytea, true)"
  );
  is($ok, 1833230522, '(2^32)-1 behaves like -2^31');
  ok(!$err, 'no error');

  # reverse
  ($ok, $err) = try_sql(
    "SELECT ix_skip32(1833230522, 'nooneknows'::bytea, false)"
  );
  is($ok, $upper_lim, "decrypting (2^32)-1 behaves");
  ok(!$err, 'no error');

  # Maximum postive number is 2147483647
  my $max_pos = (2**31)-1;
  ($ok, $err) = try_sql(
    "SELECT ix_skip32($max_pos, 'nooneknows'::bytea, true)"
  );
  is($ok, 998551349, '(2^31)-1 behaves correctly');
  ok(!$err, 'no error');

  # reverse
  ($ok, $err) = try_sql(
    "SELECT ix_skip32(998551349, 'nooneknows'::bytea, false)"
  );
  is($ok, $max_pos, "decrypting (2^31)-1 behaves");
  ok(!$err, 'no error');
}

done_testing;
