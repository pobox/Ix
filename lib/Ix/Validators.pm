use 5.22.0;
use warnings;
package Ix::Validators;

use JSON ();
use Safe::Isa;
use Ix::Util qw($ix_id_re);

use experimental qw(lexical_subs postderef signatures);

use Sub::Exporter -setup => [ qw(
  boolean email enum domain idstr integer nonemptystr simplestr freetext state
) ];

sub boolean {
  return sub ($x, @) {
    return "not a valid boolean value"
      unless $x->$_isa('JSON::PP::Boolean')
          || $x->$_isa('JSON::XS::Boolean');
    return;
  };
}

{
  my $tld_re =
    qr{
       ([-0-9a-z]+)        # top level domain
       \.?                 # possibly followed by root dot
     }xi;

  my $domain_re =
    qr{
       ([a-z0-9](?:[-a-z0-9]*[a-z0-9])?\.)+   # subdomain(s), sort of
       [-0-9a-z]+\.?
     }xi;

  my sub is_domain {
    my $value = shift;
    return unless defined $value and $value =~ /\A$domain_re\z/;
    my ($tld) = $value =~ /$tld_re\z/i;

    # We used to further check that the TLD was a valid TLD.  This made a lot
    # more sense when there was a list of, say, 50 TLDs that changed only under
    # exceptional circumstances.  I just (2016-12-16) updated the Pobox TLD
    # file from the root hosts and it added 336 new TLDs.  I think this is no
    # longer worth the effort.  We can add an email at yourface.bogus and it
    # will never be deliverable, and we'll eventually purge it because of that.
    # Fine. -- rjbs, 2016-12-16
    return 1;
  }

  my sub is_email_localpart {
    my $value = shift;

    return unless defined $value and length $value;

    my @words = split /\./, $value, -1;
    return if grep { ! length or /[\x00-\x20\x7f<>()\[\]\\.,;:@"]/ } @words;
    return 1;
  }

  my sub is_email {
    my $value = shift;

    # If we got nothing, or just blanks, it's bogus.
    return unless defined $value and $value =~ /\S/;

    return if $value =~ /\P{ASCII}/;

    # We used to strip leading and trailing whitespace, but that means that
    # is_email would return an new value, meaning that it could not accurately be
    # used as a bool.  If we need a method that does return the email address
    # eked out from a string with spaces, we should write it and then not name it
    # like a predicate.  -- rjbs, 2007-01-31

    my ($localpart, $domain) = split /@/, $value, 2;

    return unless is_email_localpart($localpart);
    return unless is_domain($domain);

    return $value;
  }

  sub email {
    return sub ($x, @) {
      return if is_email($x);
      return "not a valid email address";
    }
  }
}

sub enum ($values) {
  my %is_valid = map {; $_ => 1 } @$values;
  return sub ($x, @) {
    return "not a valid value" unless $is_valid{$x};
    return;
  };
}

sub domain {
  return sub ($x, @) {
    # XXX Obviously bogus.
    return if $x =~ /\A[-._a-z0-9]+\z/i;
    return "not a valid domain";
  };
}

sub integer ($min = '-Inf', $max = 'Inf') {
  return sub ($x, @) {
    return "not an integer" unless $x =~ /\A[-+]?(?:[0-9]|[1-9][0-9]*)\z/;
    return "value below minimum of $min" if $x < $min;
    return "value above maximum of $max" if $x > $max;
    return;
  };
}

sub state ($min = -2**31, $max = 2**31-1) {
  return sub ($x, @) {
    return "not an integer" unless $x =~ /\A[-+]?(?:[0-9]|[1-9][0-9]*)\z/;
    return "value below minimum of $min" if $x < $min;
    return "value above maximum of $max" if $x > $max;
    return;
  };
}

sub idstr {
  return sub ($x, @) {
    return "invalid id string" unless defined $x; # weak
    return "invalid id string" if ref $x;
    return "invalid id string" if $x !~ /\A$ix_id_re\z/;
    return;
  }
}

sub simplestr {
  return sub ($x, @) {
    return "not a string" unless defined $x; # weak
    return "not a string" if ref $x;
    return unless length $x;
    return "string contains only whitespace" unless $x =~ /\S/;
    return "string contains vertical whitespace" if $x =~ /\v/;
    return;
  };
}

sub nonemptystr {
  return sub ($x, @) {
    return "not a string" unless defined $x; # weak
    return "not a string" if ref $x;
    return "string is empty" unless length $x;
    return "string contains only whitespace" unless $x =~ /\S/;
    return "string contains vertical whitespace" if $x =~ /\v/;
    return;
  };
}

sub freetext {
  return sub ($x, @) {
    return "not a string" unless defined $x; # weak
    return "not a string" if ref $x;
    return unless length $x;
    return "string contains only whitespace" unless $x =~ /\S/;
    return;
  };
}

1;
