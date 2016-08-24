use 5.22.0;
use warnings;
package Ix::Validators;

use JSON ();
use Safe::Isa;

use experimental qw(postderef signatures);

use Sub::Exporter -setup => [ qw(
  boolean email enum domain integer nonemptystr simplestr
) ];

sub boolean {
  return sub ($x, @) {
    return "not a valid boolean value"
      unless $x->$_isa('JSON::PP::Boolean')
          || $x->$_isa('JSON::XS::Boolean');
    return;
  };
}

sub email {
  return sub ($x, @) {
    # XXX Obviously bogus.
    return if $x =~ /\A[-_a-z0-9.]+\@[-._a-z0-9]+\z/i;
    return "not a valid email address";
  };
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

sub simplestr {
  return sub ($x, @) {
    return "not a string" unless defined $x; # weak
    return unless length $x;
    return "string contains only whitespace" unless $x =~ /\S/;
    return "string contains vertical whitespace" if $x =~ /\v/;
    return;
  };
}

sub nonemptystr {
  return sub ($x, @) {
    return "string is empty" unless length $x;
    return "string contains only whitespace" unless $x =~ /\S/;
    return "string contains vertical whitespace" if $x =~ /\v/;
    return;
  };
}

1;
