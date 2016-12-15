use 5.20.0;
package Ix::App;

use Moose::Role;
use experimental qw(signatures postderef);

use Data::GUID qw(guid_string);
use JSON;
use Plack::Request;
use Try::Tiny;
use Safe::Isa;
use Plack::Util;
use IO::Handle;
use Time::HiRes qw(gettimeofday tv_interval);

use namespace::autoclean;

has json_codec => (
  is => 'ro',
  default => sub {
    JSON->new->utf8->pretty->allow_blessed->convert_blessed->canonical
  },
  handles => {
    encode_json => 'encode',
    decode_json => 'decode',
  },
);

has logger_json_codec => (
  is => 'ro',
  default => sub {
    JSON->new->utf8->allow_blessed->convert_blessed->canonical
  },
  handles => {
    encode_json_log => 'encode',
    decode_json_log => 'decode',
  },
);

has processor => (
  is => 'ro',
  required => 1,
);

has access_log_enabled => (
  is => 'rw',
  isa => 'Bool',
  default => 0,
);

has access_log_fh => (
  is => 'rw',
  isa => 'FileHandle',
  default => sub { IO::Handle->new->fdopen(fileno(STDERR), "w") },
);

has transaction_log_enabled => (
  is  => 'rw',
  isa => 'Bool',
  default => 0,
);

sub to_app ($self) {
  return sub ($env) {
    my $req = Plack::Request->new($env);

    my %ACCESS = (Vary => 'Origin');
    if (my $origin = $req->header('Origin')) {
      %ACCESS = (%ACCESS,
        'Access-Control-Allow-Origin' => $origin,
        'Access-Control-Allow-Credentials' => 'true',
      );
    }

    if ($req->method eq 'OPTIONS') {
      return [
        200,
        [
          %ACCESS,
          'Access-Control-Allow-Methods' => 'POST,GET,DELETE,OPTIONS',
          'Access-Control-Allow-Headers' => 'Accept,Authorization,Content-Type,X-ME-ClientVersion,X-ME-LastActivity',
          'Access-Control-Max-Age' => 86400,
        ],
        [ '' ],
      ];
    }

    state $transaction_number;
    $transaction_number++;
    $req->env->{'ix.transaction'} = {
      guid  => guid_string(),
      time  => Ix::DateTime->now,
      htime => [ gettimeofday ],
      seq   => $transaction_number,
    };

    my $ctx;
    my $res = try {
      $ctx = $self->processor->context_from_plack_request($req);
      Carp::confess("could not establish context")
        unless $ctx && $ctx->does('Ix::Context');
      $self->_core_request($ctx, $req);
    } catch {
      my $error = $_;

      # Let HTTP::Throwable pass through
      if ($error->$_can('as_psgi')) {
        my $resp = $error->as_psgi;

        if (blessed($resp)) {
          for my $k (keys %ACCESS) {
            $resp->header($k => $ACCESS{$k});
          }
        } else {
          push $resp->[1]->@*, %ACCESS;
        }

        return $resp;
      }

      my $guid = $ctx ? $ctx->report_exception($error) : undef;
      unless ($guid) {
        warn "could not report exception: $error";
      }

      return [
        500,
        [
          'Content-Type', 'application/json',
          %ACCESS,
          ($guid ? ('Ix-Request-GUID' => $guid) : ()),
        ],
        [ $self->encode_json({ error => "internal", guid => $guid }) ],
      ];
    };

    $req->env->{'ix.transaction'}{end_htime} = [ gettimeofday ];
    $req->env->{'ix.transaction'}{elapsed_seconds} = tv_interval(
      $req->env->{'ix.transaction'}{htime},
      $req->env->{'ix.transaction'}{end_htime}
    );

    $self->log_access($req, $res, $ctx) if $self->access_log_enabled;

    my @error_guids = $ctx ? $ctx->logged_exception_guids : ();

    if ($self->transaction_log_enabled || @error_guids) {
      $self->log_transaction($req, $res, $ctx);
    }

    for (@error_guids) {
      $env->{'psgi.errors'}->print("exception was reported: $_\n")
    }

    return $res;
  }
}

sub log_access ($self, $req, $res, $ctx = undef) {
  my $entry = $self->build_access_log_entry($req, $res, $ctx);

  $self->emit_access_log($entry);
}

sub build_access_log_entry ($self, $req, $res, $ctx = undef) {
  my %entry = map {
    $_ => defined $req->$_ ? $req->$_ . "" : undef
  } qw(
    remote_host
    method
    request_uri
    content_type
    content_encoding
    content_length
    referer
    user_agent
  );

  $entry{remote_ip} = $req->address;

  my $ix_info = $req->env->{'ix.transaction'};

  $entry{$_} = $ix_info->{$_} . "" for qw(
    guid time elapsed_seconds seq
  );

  if (ref($res) && ref($res) eq 'ARRAY') {
    $entry{response_code} = $res->[0];

    $entry{response_length} = Plack::Util::content_length($res->[2]);
  }

  if ($ctx) {
    $entry{call_info} = $ctx->call_info;

    $entry{exception_guids} = [ $ctx->logged_exception_guids ]
      if $ctx->logged_exception_guids;
  }

  return \%entry;
}

sub emit_access_log ($self, $entry) {
  $self->access_log_fh->print( $self->encode_json_log($entry) . "\n" );
}

sub log_transaction ($self, $req, $res, $ctx = undef) {
  my $entry = $self->build_transaction_log_entry($req, $res, $ctx);

  $self->emit_transaction_log($entry);
}

sub build_transaction_log_entry ($self, $req, $res, $ctx = undef) {
  my $entry = $self->build_access_log_entry($req, $res, $ctx);

  # Add in request/response
  $entry->{request} = $req;
  $entry->{response} = $res;

  return $entry;
}

sub emit_transaction_log ($self, $entry) {}

1;
