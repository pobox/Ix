use strict;
use warnings;
use experimental qw(postderef signatures);
package Bakesale::Schema::Result::Cookie;
use base qw/DBIx::Class::Core/;
use DateTime;
use Ix::Validators qw(idstr);
use Ix::Util qw(differ);
use List::Util qw(first);

__PACKAGE__->load_components(qw/+Ix::DBIC::Result/);

__PACKAGE__->table('cookies');

__PACKAGE__->ix_add_columns;

__PACKAGE__->ix_add_properties(
  type       => {
    data_type     => 'string',
    canonicalizer => sub ($value) { $value =~ s/ cookie\z//r; },
  },
  batch      => { data_type => 'integer', client_may_init => 0, client_may_update => 0 },
  baked_at   => { data_type => 'timestamptz', is_optional => 1 },
  expires_at => { data_type => 'timestamptz', is_optional => 0 },
  delicious  => { data_type => 'string', is_optional => 0 },
  external_id => { data_type => 'string', is_optional => 1, validator => idstr() },
);

__PACKAGE__->set_primary_key('id');

sub ix_type_key { 'cookies' }

sub ix_account_type { 'generic' }

sub ix_extra_get_args { qw(tasty) }

our $next_batch = 2;
sub ix_postprocess_set { $next_batch++ }

sub ix_default_properties {
  return {
    baked_at   => Ix::DateTime->now,
    expires_at => Ix::DateTime->now->add(days => 3),
    delicious  => 'yes',
    batch      => sub { $next_batch }
  };
}

sub ix_set_check ($self, $ctx, $arg) {
  # Tried to pass off a cake as a cookie? Throw everything out!
  if ($arg->{create} && ref $arg->{create} eq 'HASH') {
    for my $cookie (values $arg->{create}->%*) {
      if ($cookie->{type} && $cookie->{type} eq 'cake') {
        return $ctx->error(invalidArguments => {
          description => "A cake is not a cookie",
        });
      }
    }
  }

  return;
}

sub ix_create_check ($self, $ctx, $arg) {
  if (my $err = $self->_check_baked_at($ctx, $arg)) {
    return $err;
  }

  return;
}

sub ix_update_check ($self, $ctx, $row, $rec) {
  # Can't make a half-eaten cookie into a new cookie
  if (
       $rec->{type}
    && $rec->{type} !~ /eaten/i
    && $row->type =~ /eaten/i
  ) {
    return $ctx->error(partyFoul => {
      description => "You can't pretend you haven't eaten a part of that coookie!",
    });
  }

  if ($rec->{type} && $rec->{type} eq 'macaron') {
    $rec->{delicious} = 'eh';
  }

  if (my $err = $self->_check_baked_at($ctx, $rec)) {
    return $err;
  }

  return;
}

sub _check_baked_at ($self, $ctx, $arg) {
  if (my $baked_at = $arg->{baked_at}) {
    unless ($baked_at->isa('DateTime')) {
      die "How'd we get a non-object baked at?!";
    }

    if (DateTime->compare($baked_at, DateTime->now) > 0) {
      return $ctx->error(timeSpaceContinuumFoul => {
        description => "You can't claim to have baked a cookie in the future"
      });
    }
  }
}

sub ix_destroy_check ($self, $ctx, $row) {
  if ($row->type && $row->type eq 'immortal') {
    return $ctx->error(logicalFoul => {
      description => "You can't destroy an immortal cookie!",
    });
  }

  return;
}

sub ix_get_list_sort_map {
  return {
    type        => { },
    baked_at    => { },
    expires_at  => { },
    delicious   => { },
  };
}

sub ix_get_list_filter_map {
  return {
    types => {
      cond_builder => sub ($types) {
        return { type => $types },
      },
      differ => sub ($entity, $filter) {
        # This difffers if its type is not in filter list
        my $found = first { ! differ($entity->type, $_) } @$filter;

        return $found ? 0 : 1;
      },
    },
    batch => { },
  };
}

sub ix_get_list_fetchable_map { { } }

sub ix_get_list_joins { () }

sub ix_get_list_check ($self, $ctx, $arg, $search) {
  if ($arg->{filter}{types}) {
    unless ((ref($arg->{filter}{types}) || '') eq 'ARRAY') {
      return $ctx->error(invalidArguments => {
        description => "filter.types must be a list of types",
      });
    }
  }

  return;
}

sub ix_get_list_updates_check ($self, $ctx, $arg, $search) {
  return $self->ix_get_list_check($ctx, $arg, $search);
}

sub ix_get_list_enabled { 1 }

1;
