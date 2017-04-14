use 5.20.0;
package Ix::App;

use Moose::Role;
use experimental qw(signatures postderef);

use Data::GUID qw(guid_string);
use JSON::MaybeXS;
use Plack::Request;
use Try::Tiny;
use Safe::Isa;
use Plack::Util;
use Plack::Builder;
use IO::Handle;
use Time::HiRes qw(gettimeofday tv_interval);
use Plack::Middleware::ReverseProxy;

use namespace::autoclean;

has json_codec => (
  is => 'ro',
  default => sub {
    JSON::MaybeXS::JSON->new->utf8->pretty->allow_blessed->convert_blessed->canonical
  },
  handles => {
    encode_json => 'encode',
    decode_json => 'decode',
  },
);

has logger_json_codec => (
  is => 'ro',
  default => sub {
    JSON::MaybeXS::JSON->new->utf8->allow_blessed->convert_blessed->canonical
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

has _schema => (
  is => 'ro',
  lazy => 1,
  clearer => '_clear_schema',
  default => sub ($self, @) {
    $self->processor->schema_connection;
  },
);

sub to_app ($self) {
  $self->_schema; # initialize early

  my $app = sub ($env) {
    my $req = Plack::Request->new($env);

    my $guid = guid_string();

    my %HEADER = (
      Vary               => 'Origin',
      'Ix-Transaction-ID' => $guid,
    );

    if (my $origin = $req->header('Origin')) {
      %HEADER = (%HEADER,
        'Access-Control-Allow-Origin'      => $origin,
        'Access-Control-Allow-Credentials' => 'true',
      );
    }

    if ($req->method eq 'OPTIONS') {
      return [
        200,
        [
          %HEADER,
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
      guid  => $guid,
      time  => Ix::DateTime->now,
      htime => [ gettimeofday ],
      seq   => $transaction_number,
    };

    my $ctx;
    my $res = try {
      $ctx = $self->processor->context_from_plack_request(
        $req,
        { schema => $self->_schema },
      );
      Carp::confess("could not establish context")
        unless $ctx && $ctx->does('Ix::Context');
      $self->_core_request($ctx, $req);
    } catch {
      my $error = $_;

      # Let HTTP::Throwable pass through
      if ($error->$_can('as_psgi')) {
        return $error->as_psgi;
      }

      my $guid = $ctx ? $ctx->report_exception($error) : undef;
      unless ($guid) {
        warn "could not report exception: $error";
      }

      return [
        500,
        [
          'Content-Type', 'application/json; charset=utf-8',
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

    if (blessed($res)) {
      for my $k (keys %HEADER) {
        $res->header($k => $HEADER{$k});
      }
    } elsif (ref($res) ne 'CODE') {
      # Danger here is we set multiple values for these headers...
      push $res->[1]->@*, %HEADER;
    }

    return $res;
  };

  if ($self->processor->behind_proxy) {
    my $builder = Plack::Builder->new;
    $builder->add_middleware('ReverseProxy');
    $app = $builder->wrap($app);
  }

  return $app;
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
