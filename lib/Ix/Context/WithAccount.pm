use 5.20.0;
package Ix::Context::WithAccount;

use Moose::Role;
use experimental qw(signatures postderef);

use Ix::Error;
use Ix::Result;

use Ix::AccountState;

use Try::Tiny;

use namespace::autoclean;

requires 'account_type';
requires 'accountId';

has root_context => (
  is     => 'ro',
  does   => 'Ix::Context',
  required => 1,
  handles  => [ qw(
    schema
    processor
    global_rs
    global_rs_including_inactive

    get_created_id log_created_id

    log_exception_guid
    report_exception

    record_call_info
    _save_states

    error
    internal_error
    result

    results_so_far

    may_call
  ) ],
);

has _txn_level => (
  is => 'rw',
  isa => 'Int',
  init_arg => undef,
  default => 0,
);

has state => (
  is => 'rw',
  isa => 'Ix::AccountState',
  lazy => 1,
  builder => '_build_state',
  predicate => '_has_state',
);

sub _build_state ($self) {
  Ix::AccountState->new({
    context      => $self,
    account_type => $self->account_type,
    accountId    => $self->accountId,
  });
}

# A wrapper around DBIC's txn_do. What this does is:
#
#  * increment our transaction depth
#  * localize our copy of the pending states
#  * Run the transaction
#  * If it succeeds, we copy out the states that actually need changing
#    and ship them up to our outer scope. This ensures that we don't
#    record state changes in internal calls to ix_set if something fails
#    somewhere along the way.
#  * decrement our transaction depth. If depth reaches 0, that means we're
#    at the start of the transaction and we need to commit state changes
#
# This should probably only be used by ix_set() and any calls it makes
# internally that may try to bump state (generally, anything that may lead
# to a nested ix_set).
sub txn_do ($self, $code) {
  return $self->schema->txn_do(sub {
    if (
         $self->_txn_level == 0
      && $self->_has_state
    ) {
      # We should *NOT* have gotten any state information before starting
      # a brand new transaction tree. If so, something is wrong.
      require Carp;
      Carp::confess("We already have state before starting a transaction?!");
    }

    # Start of a tree? Localize state so it goes away when we're done
    local $self->{state} = $self->_build_state if $self->_txn_level == 0;

    my $state = $self->state;

    my @rv;
    my $inner = { $state->_pending_states->%* };

    {
      # Localize txn level and pending states and  for next ix_* calls that
      # may happen
      local $self->{_txn_level} = $self->_txn_level + 1;
      local $state->{_pending_states} = $inner;

      @rv = $code->();
    }

    # Copy any actually bumped states up
    for my $k (keys %$inner) {
      $state->_pending_states->{$k} = $inner->{$k};
    }

    # Are we the start of this tree? Commit the state changes if any
    if ($self->_txn_level == 0) {
      try {
        $state->_save_states;
      } catch {
        my $error = $_;

        if ($error =~ /unique.*states_pkey/i) {
          $self->error('tryAgain' => {
            description => "blocked by another client",
          })->throw;
        }

        # What even happened?
        die $error;
      };
    }

    return @rv;
  });
}

sub process_request ($self, $calls) {
  $self->processor->process_request($self, $calls);
}

sub account_rs ($self, $rs_name) {
  my $rs = $self->schema->resultset($rs_name)->search({
    'me.accountId' => $self->accountId,
  });

  if ($rs->result_class->isa('Ix::DBIC::Result')) {
    $rs = $rs->search({ 'me.isActive' => 1 });
  }

  return $rs;
}

sub account_rs_including_inactive ($self, $rs_name) {
  $self->schema->resultset($rs_name)->search({
    'me.accountId' => $self->accountId,
  });
}

sub with_account ($self, $account_type, $accountId) {
  if (
    $account_type eq $self->account_type
    &&
    ($accountId // $self->accountId) eq $self->accountId
  ) {
    return $self;
  }

  $self->internal_error("conflicting recontextualization")->throw;
}

1;
