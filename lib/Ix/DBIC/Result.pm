use 5.20.0;
use warnings;
package Ix::DBIC::Result;

use parent 'DBIx::Class';

use experimental qw(signatures postderef);

use Ix::StateComparison;
use Ix::Validators;

sub ix_account_type { Carp::confess("ix_account_type not implemented") }

sub ix_type_key { Carp::confess("ix_type_key not implemented") }
sub ix_type_key_singular ($self) {
  $self->ix_type_key =~ s/s\z//r;
}

sub ix_get_list_enabled {}
sub ix_extra_get_args { }

sub ix_virtual_property_names ($self, @) {
  my $prop_info = $self->ix_property_info;
  return grep {; $prop_info->{$_}{is_virtual} } keys %$prop_info;
}

sub ix_property_names ($self, @) {
  return keys $self->ix_property_info->%*;
}

sub ix_mutable_properties ($self, $ctx) {
  my $prop_info = $self->ix_property_info;

  if ($ctx->root_context->is_system) {
    return keys %$prop_info;
  }

  return
    grep {; ! $prop_info->{$_}{is_immutable} && ! $prop_info->{$_}{is_virtual} }
    keys %$prop_info;
}

sub ix_default_properties { return {} }

sub ix_add_columns ($class) {
  $class->ix_add_properties(
    id            => {
      data_type     => 'string',
      db_data_type  => 'integer',
      default_value => \q{pseudo_encrypt(nextval('key_seed_seq')::int)},
      is_immutable  => 1,
    },
  );

  $class->add_columns(
    accountId     => { data_type => 'integer' },
    modSeqCreated => { data_type => 'integer' },
    modSeqChanged => { data_type => 'integer' },
    dateDeleted   => { data_type => 'datetime', is_nullable => 1 },
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
  string   => { data_type => 'text' },
  datetime => { data_type => 'timestamptz' },

  boolean  => { data_type => 'boolean' },
  integer  => { data_type => 'integer', is_numeric => 1 },
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
  string  => Ix::Validators::simplestr(),
  boolean => Ix::Validators::boolean(),
);

my %DID_FINALIZE;
sub ix_finalize ($class) {
  if ($DID_FINALIZE{$class}++) {
    Carp::confess("tried to finalize $class a second time");
  }

  my $prop_info = $class->ix_property_info;

  for my $name (keys %$prop_info) {
    my $info = $prop_info->{$name};

    $info->{validator} //= $DEFAULT_VALIDATOR{ $info->{data_type} };
  }
}

sub ix_set_check { return; } # ($self, $ctx, \%arg)

sub ix_get_check     { } # ($self, $ctx, \%arg)
sub ix_create_check  { } # ($self, $ctx, \%rec)
sub ix_update_check  { } # ($self, $ctx, $row, \%rec)
sub ix_destroy_check { } # ($self, $ctx, $row)

sub ix_create_error  { return; } # ($self, $ctx, \%error)
sub ix_update_error  { return; } # ($self, $ctx, \%error)

sub ix_created   { } # ($self, $ctx, $row)
sub ix_updated   { } # ($self, $ctx, $row)
sub ix_destroyed { } # ($self, $ctx, $row)

sub ix_postprocess_create  { } # ($self, $ctx, \@rows)
sub ix_postprocess_update  { } # ($self, $ctx, \@row_ids)
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
        'me.dateDeleted' => undef,
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

sub ix_update_single_state_conds ($self, $example_row) {
  return { 'me.modSeqChanged' => $example_row->{modSeqChanged} }
}

sub ix_compare_state ($self, $since, $state) {
  my $high_ms = $state->highest_modseq_for($self->ix_type_key);
  my $low_ms  = $state->lowest_modseq_for($self->ix_type_key);

  state $bad_idstr = Ix::Validators::idstr();

  if ($bad_idstr->($since)) {
    return Ix::StateComparison->bogus;
  }

  if ($high_ms  < $since) { return Ix::StateComparison->bogus;   }
  if ($low_ms   > $since) { return Ix::StateComparison->resync;  }
  if ($high_ms == $since) { return Ix::StateComparison->in_sync; }

  return Ix::StateComparison->okay;
}

1;
