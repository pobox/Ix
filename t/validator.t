use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

BEGIN { binmode $_, ':encoding(UTF-8)' for *STDOUT, *STDERR };

use lib 't/lib';

use Ix::Validators qw(domain email idstr string);
use Test::More;
use Ix::Util qw(ix_new_id);

my $iderr = idstr();
for my $input (ix_new_id(), ix_new_id()) {
  ok( ! $iderr->($input), "$input is a valid idstr");
}

for my $input (qw( -0 +0 +1 banana ab-cd-ef), uc ix_new_id()) {
  ok( $iderr->($input), "$input is not a valid idstr");
}

subtest "domain validator" => sub {
  my $domerr = domain();

  my @domains = qw( xyz.com  your-face.com pobox.co.nz );
  ok(! $domerr->($_), "$_ is a valid domain") for @domains;

  my @bogus = ('not a domain', qw(not-a-domain www.example.com.));
  ok(  $domerr->($_), "$_ is not a valid domain") for @bogus;
};

subtest "email validator" => sub {
  my $emailerr = email();
  ok( $emailerr->('yourface@myface.ix.'), "trailing dots no good in email");
};

my @tests = (
  {
    config  => { ascii => 1 },
    pass    => [ qw( foo bar baz ), "foo\nbar" ],
    fail    => [ qw( fóo 🇭🇰  ), "x\N{U+00A0}y" ],
  },
  {
    config  => { nonempty => 1 },
    pass    => [ q{x} ],
    fail    => [ q{}, q{ } ], # space fails because it's all non-graphic
  },
  {
    config  => { nonempty => 1, printable => 0 },
    pass    => [ q{x}, q{ } ],
    fail    => [ q{} ],
  },
  {
    config  => { oneline => 1 },
    pass    => [ "foo", "foo bar" ],
    fail    => [ "foo\nbar", "foo\N{VERTICAL TABULATION}bar" ],
  },
  {
    config  => { trimmed => 1 },
    pass    => [ "foobar", "foo bar" ],
    fail    => [ " foo bar", "foo bar ", " foo bar " ],
  },
  {
    config  => { printable => 1 },
    pass    => [ "foo", "foo\N{COMBINING DIAERESIS}" ],
    fail    => [ q{ }, qq{\t}, "\N{COMBINING DIAERESIS}" ],
  },
);

my $JSON = JSON::MaybeXS->new->canonical;
for my $test (@tests) {
  my $desc = $JSON->encode($test->{config});
  my $chk  = string($test->{config});

  subtest "string( $desc )" => sub {
    for my $pass (@{ $test->{pass} // [] }) {
      my $printable = $pass =~ s/(\v|\P{ASCII})/sprintf '\N{U+%04X}', ord $1/egr;
      is($chk->($pass), undef, "no error for qq{$printable}");
    }

    for my $fail (@{ $test->{fail} // [] }) {
      my $printable = $fail =~ s/(\v|\P{ASCII})/sprintf '\N{U+%04X}', ord $1/egr;
      if (my $error = $chk->($fail)) {
        pass("error for qq{$printable}: $error");
      } else {
        fail("error for qq{$printable}");
      }
    }
  };
}

done_testing;
