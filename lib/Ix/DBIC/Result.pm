use 5.20.0;
use warnings;
package Ix::DBIC::Result;

use parent 'DBIx::Class';

use experimental qw(signatures postderef);

use Ix::StateComparison;
use Ix::Validators;
use Ix::Util qw(ix_new_id);
use JSON::MaybeXS;

__PACKAGE__->load_components(qw/+Ix::DBIC::AccountResult/);

sub ix_account_type { Carp::confess("ix_account_type not implemented") }

# Checked for in ix_finalize
# sub ix_type_key { }

sub ix_get_list_enabled {}
sub ix_extra_get_args { }

# Must be specified if the rclass represents a new 'account'
sub ix_is_account_base { 0 }

sub ix_virtual_property_names ($self, @) {
  my $prop_info = $self->ix_property_info;
  return grep {; $prop_info->{$_}{is_virtual} } keys %$prop_info;
}

sub ix_property_names ($self, @) {
  return keys $self->ix_property_info->%*;
}

sub ix_client_update_ok_properties ($self, $ctx) {
  my $prop_info = $self->ix_property_info;

  if ($ctx->root_context->is_system) {
    return
      grep {;    ! $prop_info->{$_}{is_virtual}
              && ! $prop_info->{$_}{is_immutable} }
      keys %$prop_info;
  }

  return
    grep {;      $prop_info->{$_}{client_may_update}
            && ! $prop_info->{$_}{is_virtual}
            && ! $prop_info->{$_}{is_immutable} }
    keys %$prop_info;
}

sub ix_client_init_ok_properties ($self, $ctx) {
  my $prop_info = $self->ix_property_info;

  if ($ctx->root_context->is_system) {
    return keys %$prop_info;
  }

  return
    grep {; $prop_info->{$_}{client_may_init} && ! $prop_info->{$_}{is_virtual} }
    keys %$prop_info;
}

sub ix_default_properties { return {} }

sub new ($class, $attrs) {
  # Are we an actual Ix result?
  if ($class->can('ix_type_key')) {
    $attrs->{id} //= ix_new_id();
  }

  return $class->next::method($attrs);
}

sub ix_add_columns ($class) {
  $class->ix_add_properties(
    id            => {
      data_type     => 'idstr',
      client_may_init   => 0,
      client_may_update => 0,
    },
  );

  $class->add_columns(
    accountId     => { data_type => 'uuid' },
    created       => { data_type => 'timestamptz', default_value => \'NOW()' },
    modSeqCreated => { data_type => 'integer' },
    modSeqChanged => { data_type => 'integer' },
    dateDestroyed => { data_type => 'timestamptz', is_nullable => 1 },
    isActive      => { data_type => 'boolean', is_nullable => 1, default_value => 1 },
  );
}

# Since ix_destroy doesn't actually delete rows, we need a way for unique
# constraints to work while letting rows stick around. What we're doing is
# injecting a column (isActive) into the beginning of the unique constraints
# that has only two possible values: true on create, and NULL when the row
# is destroyed. While the value is true, it allows the unique constraint to work.
# When the value becomes NULL, it will no longer ever match any other rows, and
# so will not get in the way of active data (in Postgres, NULL is never equal
# to NULL).
sub ix_add_unique_constraints ($class, @constraints) {
  for my $c (@constraints) {
    if (ref $c) {
      unshift @$c, 'isActive';
    }
  }

  $class->add_unique_constraints(@constraints);
}

sub ix_add_unique_constraint ($class, @constraint) {
  $class->ix_add_unique_constraints(@constraint);
}

my %IX_TYPE = (
  # idstr should get done this way in the future
  string       => { data_type => 'text' },
  istring      => { data_type => 'citext' },
  timestamptz  => { data_type => 'timestamptz' },

  # We don't provide istring[] because DBD::Pg doesn't work nicely with it yet:
  # https://rt.cpan.org/Public/Bug/Display.html?id=54224
  'string[]'   => { data_type => 'text[]' },

  boolean      => { data_type => 'boolean' },
  integer      => { data_type => 'integer', is_numeric => 1 },
  idstr        => { data_type => 'uuid', },
);

sub ix_add_properties ($class, @pairs) {
  my %info = @pairs;

  while (my ($name, $def) = splice @pairs, 0, 2) {
    next if $def->{is_virtual};

    Carp::confess("Attempt to add property $name with no data_type")
      unless defined $def->{data_type};

    my $ix_type = $IX_TYPE{ $def->{data_type} };

    Carp::confess("Attempt to add property $name with unknown data_type $def->{data_type}")
      unless $ix_type && $ix_type->{data_type};

    my $col_info = {
      is_nullable   => $def->{is_optional} ? 1 : 0,
      default_value => $def->{default_value},
      %$ix_type,

      ($def->{db_data_type} ? (data_type => $def->{db_data_type}) : ()),
    };

    $class->add_columns($name, $col_info);

    if ($def->{data_type} eq 'boolean') {
      # So differ() can compare these to API inputs sensibly
      $class->inflate_column($name, {
        inflate => sub ($raw_value_from_db, $result_object) {
          return $raw_value_from_db ? JSON->true : JSON->false;
        },
        deflate => sub ($input_value, $result_object) {
          $input_value ? 1 : 0,
        },
      });
    }
  }

  if ($class->can('ix_property_info')) {
    my $stored = $class->ix_property_info;
    for my $prop (keys %info) {
      Carp::confess("attempt to re-add property $prop") if $stored->{$prop};
      $stored->{$prop} = $info{$prop};
    }
  } else {
    my $reader = sub ($self) { return \%info };
    Sub::Install::install_sub({
      code => $reader,
      into => $class,
      as   => 'ix_property_info',
    });
  }

  return;
}

my %DEFAULT_VALIDATOR = (
  integer => Ix::Validators::integer(),
  string  => Ix::Validators::string({ oneline => 1 }),
  istring => Ix::Validators::string({ oneline => 1 }),
  boolean => Ix::Validators::boolean(),
  idstr   => Ix::Validators::idstr(),
);

my %DID_FINALIZE;
sub ix_finalize ($class) {
  if ($DID_FINALIZE{$class}++) {
    Carp::confess("tried to finalize $class a second time");
  }

  unless ($class->can('ix_type_key')) {
    Carp::confess("Class $class must define an 'ix_type_key' method");
  }

  my $prop_info = $class->ix_property_info;

  if ($class->ix_get_list_enabled) {
    my @missing;

    for my $method (qw(
      ix_get_list_check
      ix_get_list_updates_check
      ix_get_list_filter_map
      ix_get_list_sort_map
      ix_get_list_joins
    )) {
      push @missing, $method unless $class->can($method);
    }

    if (@missing) {
      Carp::confess(
          "$class - ix_get_list_enabled is true but these required methods are missing: "
        . join(', ', @missing)
      );
    }

    # Ensure filters are diffable. If they aren't we'll crash in
    # ix_get_list_updates when trying to figure out if something has changed.
    # For now, we require that either:
    #
    #  - The filter is a property of the class (it's in by ix_property_info)
    #  - The filter specifies its own custom differ
    #  - The filter contains a relationship ('this.that') and the relationship
    #    is listed as joinable in ix_get_list_joins. (Note that we do
    #    not verify the columns on the related tables... yet...)
    my @broken;

    my $fmap = $class->ix_get_list_filter_map;

    my %joins = map { $_ => 1 } $class->ix_get_list_joins;

    for my $k (keys %$fmap) {
      my $rel_ok;

      if ($k =~ /\./) {
        my ($rel) = $k =~ /^([^.]+?)\./;

        $rel_ok = $joins{$rel};
      }

      unless (
           $prop_info->{$k}
        || $fmap->{$k}->{differ}
        || $rel_ok
      ) {
        push @broken, $k;
      }
    }

    if (@broken) {
      Carp::confess(
          "$class - ix_get_list_filter_map has filters that don't match columns or have custom differs: "
        . join(', ', @broken)
      );
    }
  }

  for my $name (keys %$prop_info) {
    my $info = $prop_info->{$name};

    $info->{client_may_update} = 1 unless exists $info->{client_may_update};
    $info->{client_may_init}   = 1 unless exists $info->{client_may_init};
    $info->{validator} //= $DEFAULT_VALIDATOR{ $info->{data_type} };
  }
}

sub ix_set_check { return; } # ($self, $ctx, \%arg)

sub ix_get_check              { } # ($self, $ctx, \%arg)
sub ix_create_check           { } # ($self, $ctx, \%rec)
sub ix_update_check           { } # ($self, $ctx, $row, \%rec)
sub ix_destroy_check          { } # ($self, $ctx, $row)
sub ix_get_updates_check      { } # ($self, $ctx, \%arg)

sub ix_create_error  { return; } # ($self, $ctx, \%error)
sub ix_update_error  { return; } # ($self, $ctx, \%error)

sub ix_created   { } # ($self, $ctx, $row)
sub ix_destroyed { } # ($self, $ctx, $row)

# The input to ix_updated is not trivial to compute, so it is only called if
# present, so we don't define it in the base class. -- rjbs, 2017-01-06
# sub ix_updated   { } # ($self, $ctx, $row, \%changes)

sub ix_postprocess_create  { } # ($self, $ctx, \@rows)
sub ix_postprocess_update  { } # ($self, $ctx, \%updated)
sub ix_postprocess_destroy { } # ($self, $ctx, \@row_ids)

sub _return_ix_get   { return $_[3]->@* }

sub ix_update_state_string_field { 'modSeqChanged' }

sub ix_state_string ($self, $state) {
  return $state->state_for( $self->ix_type_key ) . "";
}

sub ix_get_extra_search ($self, $ctx, $arg = {}) {
  return (
    {},
    {},
  );
}

sub ix_update_extra_search ($self, $ctx, $arg) {
  my $since = $arg->{since};

  return (
    {
      'me.modSeqChanged' => { '>' => $since },

      # Don't include rows that were created and deleted after
      # our current state
      -or => [
        'me.isActive' => 1,
        'me.modSeqCreated' => { '<=' => $since },
      ],
    },
    {},
  );
}

sub ix_update_extra_select {
  return [];
}

sub ix_highest_state ($self, $since, $rows) {
  my $state_string_field = $self->ix_update_state_string_field;
  return $rows->[-1]{$state_string_field};
}

sub ix_item_created_since ($self, $item, $since) {
  return $item->{modSeqCreated} > $since;
}

sub ix_update_single_state_conds ($self, $example_row) {
  return { 'me.modSeqChanged' => $example_row->{modSeqChanged} }
}

sub ix_compare_state ($self, $since, $state) {
  my $high_ms = $state->highest_modseq_for($self->ix_type_key);
  my $low_ms  = $state->lowest_modseq_for($self->ix_type_key);

  state $bad_state = Ix::Validators::state();

  if ($bad_state->($since)) {
    return Ix::StateComparison->bogus;
  }

  if ($high_ms  < $since) { return Ix::StateComparison->bogus;   }
  if ($low_ms   > $since) { return Ix::StateComparison->resync;  }
  if ($high_ms == $since) { return Ix::StateComparison->in_sync; }

  return Ix::StateComparison->okay;
}

sub ix_create_base_state ($self) {
  unless ($self->ix_is_account_base) {
    require Carp;
    Carp::croak("ix_create_base_state(): $self is not a base account type!");
  }

  my $schema = $self->result_source->schema;

  my $source_reg = $schema->source_registrations;

  for my $moniker (keys %$source_reg) {
    my $rclass = $source_reg->{$moniker}->result_class;
    next unless $rclass->can('ix_account_type');

    if ($rclass->ix_account_type eq $self->ix_account_type) {
      $schema->resultset('State')->create({
        accountId     => $self->accountId,
        type          => $rclass->ix_type_key,
        highestModSeq => 0,
        lowestModSeq  => 0,
      });
    }
  }
}

1;
