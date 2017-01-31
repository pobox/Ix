use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Ix::Validators 'idstr';
use Test::More;

my $iderr = idstr();
for my $input (qw( 0 1 4294967295)) {
  ok( ! $iderr->($input), "$input is a valid idstr");
}

for my $input (qw( -0 +0 +1 banana 4294967296 )) {
  ok( $iderr->($input), "$input is not a valid idstr");
}

done_testing;
