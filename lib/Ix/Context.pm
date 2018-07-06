use 5.20.0;
package Ix::Context;

use Moose::Role;
use experimental qw(signatures postderef);

use Ix::Error;
use Ix::Result;
use Safe::Isa;

use namespace::autoclean;

requires 'with_account'; # $dctx = $ctx->with_account(type => optional_id)
requires 'is_system';

sub root_context ($self) { $self }

has schema => (
  is   => 'ro',
  required => 1,
  handles  => [ qw( global_rs global_rs_including_inactive ) ],
);

has processor => (
  is   => 'ro',
  does => 'Ix::Processor',
  required => 1,
);

has created_ids => (
  is => 'ro',
  reader   => '_created_ids',
  init_arg => undef,
  default  => sub {  {}  },
);

has call_info => (
  is => 'ro',
  traits   => [ 'Array' ],
  handles  => {
    _add_call_info => 'push',
  },

  default => sub { [] },
);

sub record_call_info ($self, $call, $info) {
  $self->_add_call_info([ $call, $info ]);
}

sub log_created_id ($self, $type, $creation_id, $id) {
  my $reg = ($self->_created_ids->{$type} //= {});

  if ($reg->{$creation_id}) {
    $reg->{$creation_id} = \undef;
  } else {
    $reg->{$creation_id} = $id;
  }

  return;
}

sub get_created_id ($self, $type, $creation_id) {
  my $id = $self->_created_ids->{$type}{$creation_id};

  $self->error(duplicateCreationId => {})->throw
    if ref $id && ! defined $$id;

  return $id;
}

has result_accumulator => (
  init_arg  => undef,
  predicate => 'is_handling_calls',
  reader    => '_result_accumulator',
);

sub results_so_far ($self) {
  $self->internal_error("tried to inspect results outside of request")->throw
    unless $self->is_handling_calls;

  return $self->_result_accumulator;
}

sub handle_calls ($self, $calls, $arg = {}) {
  $self->processor->handle_calls($self, $calls, $arg);
}

sub process_request ($self, $calls) {
  $self->processor->process_request($self, $calls);
}

has logged_exception_guids => (
  init_arg => undef,
  lazy     => 1,
  default  => sub {  []  },
  traits   => [ 'Array' ],
  handles  => {
    logged_exception_guids => 'elements',
    log_exception_guid     => 'push',
  },
);

sub report_exception ($ctx, $exception) {
  # Ix::Error::Internals are created after we've already reported an
  # exception, so don't throw them again
  return $exception->report_guid if $exception->$_isa('Ix::Error::Internal');

  my $guid = $ctx->processor->file_exception_report($ctx, $exception);
  $ctx->log_exception_guid($guid);
  return $guid;
}

sub error ($ctx, $type, $prop = {}, $ident = undef, $payload = undef) {
  my $report_guid;
  if (defined $ident) {
    my $report = Ix::ExceptionWrapper->new({
      ident => $ident,
      ($payload ? (payload => $payload) : ()),
    });

    $report_guid = $ctx->report_exception($report);
  }

  Ix::Error::Generic->new({
    error_type => $type,
    properties => $prop,
    ($report_guid ? (report_guid => $report_guid) : ()),
  });
}

sub internal_error ($ctx, $ident, $payload = undef) {
  my $report = Ix::ExceptionWrapper->new({
    ident => $ident,
    ($payload ? (payload => $payload) : ()),
  });

  my $report_guid = $ctx->report_exception($report);

  Ix::Error::Internal->new({
    error_ident => $ident,
    report_guid => $report_guid,
  });
}

sub result ($ctx, $type, $prop = {}) {
  Ix::Result::Generic->new({
    result_type       => $type,
    result_arguments => $prop,
  });
}

sub result_without_accountid ($ctx, $type, $prop = {}) {
  return $ctx->result($type, $prop);
}

sub may_call { 1 }

1;
