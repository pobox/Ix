use 5.20.0;
use warnings;
package Ix::DBIC::ResultSet;

use parent 'DBIx::Class::ResultSet';

use experimental qw(signatures postderef);

use Ix::Util qw(parsedate parsepgdate);
use JSON (); # XXX temporary?  for false() -- rjbs, 2016-02-22
use List::MoreUtils qw(uniq);
use Safe::Isa;
use Ix::Validators qw(idstr);

use namespace::clean;

# XXX Worth caching?  Probably. -- rjbs, 2016-05-10
sub _ix_rclass ($self) {
  my $rclass = $self->result_source->result_class;

  # Can this happen?  Who knows, probably! -- rjbs, 2016-02-20
  Carp::confess("called with non-Ix-compatible result class: $rclass")
    unless $rclass->isa('Ix::DBIC::Result');

  return $rclass;
}

sub ix_get ($self, $ctx, $arg = {}) {
  my $datasetId = $ctx->datasetId;

  my $rclass    = $self->_ix_rclass;

  # XXX This is crap. -- rjbs, 2016-04-29
  $arg = $rclass->ix_preprocess_get_arg($ctx, $arg)
    if $rclass->can('ix_preprocess_get_arg');

  my $ids   = $arg->{ids};
  my $since = $arg->{sinceState};

  state $bad_idstr = Ix::Validators::idstr();

  if (defined $since && $bad_idstr->($since)) {
    $ctx->error(
      invalidArguments => { description => "invalid sinceState" }
    )->throw;
  }

  my $prop_info = $rclass->ix_property_info;
  my %is_prop   = map  {; $_ => 1 }
                  (grep {; ! $prop_info->{$_}{ix_hidden} } keys %$prop_info),
                  ($rclass->ix_virtual_property_names);

  my @props;
  if ($arg->{properties}) {
    if (my @invalid = grep {; ! $is_prop{$_} } $arg->{properties}->@*) {
      return $ctx->error("invalidArguments", {
        description       => "requested unknown property",
        unknownProperties => \@invalid,
      });
    }

    @props = uniq('id', $arg->{properties}->@*);
  } else {
    @props = keys %is_prop;
  }

  if (my $error = $rclass->ix_get_check($ctx, $arg)) {
    return $error;
  }

  my ($x_get_cond, $x_get_attr) = $rclass->ix_get_extra_search(
    $ctx,
    {
      properties => \@props,
    },
  );

  my @ids;

  if ($ids) {
    for my $id (@$ids) {
      push @ids, $id unless $bad_idstr->($id);
    }
  }

  my %is_virtual = map {; $_ => 1 } $rclass->ix_virtual_property_names;
  my @rows = $self->search(
    {
      datasetId => $datasetId,
      (defined $since ? (modSeqChanged => { '>' => $since }) : ()),
      ($ids ? (id => \@ids) : ()),
      dateDeleted => undef,
      %$x_get_cond,
    },
    {
      select => [ grep {; ! $is_virtual{$_} } @props ],
      result_class => 'DBIx::Class::ResultClass::HashRefInflator',
      %$x_get_attr,
    },
  )->all;

  $self->_ix_wash_rows(\@rows);

  my @not_found;
  if ($ids) {
    my %found  = map  {; $_->{id} => 1 } @rows;
    @not_found = grep {; ! $found{$_} } @$ids;
  }

  return $rclass->_return_ix_get(
    $ctx,
    $arg,
    [
      $ctx->result($rclass->ix_type_key => {
        state => $rclass->ix_state_string($ctx->state),
        list  => \@rows,
        notFound => (@not_found ? \@not_found : undef),
      }),
    ]
  );
}

sub ix_get_updates ($self, $ctx, $arg = {}) {
  my $datasetId = $ctx->datasetId;

  my $since = $arg->{sinceState};

  return $ctx->error(invalidArguments => { description => "no sinceState given" })
    unless defined $since;

  my $limit = $arg->{maxChanges};
  if (defined $limit && ( $limit !~ /^[0-9]+\z/ || $limit == 0 )) {
    return $ctx->error(invalidArguments => { description => "invalid maxChanges" });
  }

  my $rclass   = $self->_ix_rclass;
  my $type_key = $rclass->ix_type_key;
  my $schema   = $self->result_source->schema;
  my $res_type = $rclass->ix_type_key_singular . "Updates";

  my $statecmp = $rclass->ix_compare_state($since, $ctx->state);

  die "wtf happened" unless $statecmp->$_isa('Ix::StateComparison');

  if ($statecmp->is_in_sync) {
    return $ctx->result($res_type => {
      oldState => "$since",
      newState => "$since",
      hasMoreUpdates => JSON::false(), # Gross. -- rjbs, 2016-02-21
      changed => [],
      removed => [],
    });
  }

  if ($statecmp->is_bogus) {
    $ctx->error(invalidArguments => { description => "invalid sinceState" })->throw;
  }

  if ($statecmp->is_resync) {
    $ctx->error(cannotCalculateChanges => {
      description => "client cache must be reconstucted"
    })->throw
  }

  my ($x_update_cond, $x_update_attr) = $rclass->ix_update_extra_search($ctx, {
    since => $since,
  });

  my $state_string_field = $rclass->ix_update_state_string_field;

  my $search = $self->search(
    {
      'me.datasetId'     => $datasetId,
      %$x_update_cond,
    },
    {
      select => [
        'id',
        qw(me.dateDeleted me.modSeqChanged),
        $rclass->ix_update_extra_select->@*,
      ],
      result_class => 'DBIx::Class::ResultClass::HashRefInflator',
      order_by => 'me.modSeqChanged',
      %$x_update_attr,
    },
  );

  my @rows = $search->search(
    {},
    {
      ($limit ? (rows => $limit + 1) : ()),
    },
  )->all;

  my $hasMoreUpdates = 0;

  if ($limit && @rows > $limit) {
    # So, the user asked for (say) 100 rows.  We'll drop the whole set of
    # records from the highest-seen state, and let the user know that more
    # changes await.  We ask for one more row than is needed so that if we were
    # at a state boundary, we can get the limit-count worth of rows by dropping
    # only the superfluous one. -- rjbs, 2016-05-04
    $hasMoreUpdates = 1;

    my $maxState = $rows[$limit]{$state_string_field};
    my @trimmed_rows = grep { $_->{$state_string_field} ne $maxState } @rows;

    if (@trimmed_rows == 0) {
      # ... well, it turns out that the entire batch was in one state.  We
      # can't possibly provide a consistent update within the bounds that the
      # user requested.  When this happens, we're permitted to provide more
      # records than requested, so let's just fetch one state worth of
      # records. -- rjbs, 2016-02-22
      @rows = $search->search(
        $rclass->ix_update_single_state_conds($rows[0])
      )->all;
    } else {
      @rows = @trimmed_rows;
    }
  }

  my @changed;
  my @removed;
  for my $item (@rows) {
    if ($item->{dateDeleted}) {
      push @removed, "$item->{id}";
    } else {
      push @changed, "$item->{id}";
    }
  }

  my @return = $ctx->result($res_type => {
    oldState => "$since",
    newState => ($hasMoreUpdates
              ? $rclass->ix_highest_state($since, \@rows)
              : $rclass->ix_state_string($ctx->state)),
    hasMoreUpdates => $hasMoreUpdates ? JSON::true() : JSON::false(),
    changed => \@changed,
    removed => \@removed,
  });

  if ($arg->{fetchRecords}) {
    # XXX This is pretty sub-optimal, because we might be passing a @changed of
    # size 500+, which becomes 500 placeholder variables.  Stupid.  If it comes
    # to it, we could maybe run-encode them with BETWEEN queries.
    #
    # We used to do a *single* select, which was a nice optimization, but it
    # bypassed permissions imposed by "get" query extras.  We need to *not* use
    # those in getting updates, but to use them in getting records.
    #
    # Next attempt was to use a ResultSetColumn->as_query on the above query's
    # id column.  That's no good because we're manually trimming the results
    # based on id boundaries.  We may be able to improve the above query, then
    # use this strategy.  For now, just gonna let it go until we hit problems!
    # -- rjbs, 2016-06-08
    push @return, $self->ix_get($ctx, {
      ids => \@changed,
      properties => $arg->{fetchRecordProperties},
    });
  }

  return @return;
}

sub ix_purge ($self, $ctx) {
  my $datasetId = $ctx->datasetId;

  my $rclass = $self->_ix_rclass;

  my $type_key = $rclass->ix_type_key;

  my $since = Ix::DateTime->from_epoch(epoch => time - 86400 * 7);

  my $rs = $self->search({
    datasetId   => $datasetId,
    dateDeleted => { '<', $since->as_string },
  });

  my $maxDeletedModSeq = $self->get_column('modSeqChanged')->max;

  $rs->delete;

  # XXX: violating encapsulation
  my $state_row = $ctx->state->_state_rows->{$type_key};

  $state_row->lowestModSeq( $maxDeletedModSeq )
    if $maxDeletedModSeq > $state_row->lowestModSeq;

  return;
}

sub ix_create ($self, $ctx, $to_create) {
  my $datasetId = $ctx->datasetId;

  my $rclass = $self->_ix_rclass;

  my $type_key = $rclass->ix_type_key;

  my $next_state = $ctx->state->next_state_for($type_key);

  my %result;

  # TODO do this once during ix_finalize -- rjbs, 2016-05-10
  my %is_user_prop = map {; $_ => 1 } $rclass->ix_mutable_properties($ctx);

  my $prop_info = $rclass->ix_property_info;

  # TODO: sort these in dependency order, so if item A references item B, B is
  # created first -- rjbs, 2016-05-10
  my @keys = keys $to_create->%*;

  TO_CREATE: for my $id (@keys) {

    my %default_properties = (
      # XXX: This surely must require a lot more customizability; pass in
      # context, user props, blah blah blah.  A bigger question is whether we
      # can have this work only on context, and not on the properties so far.
      # (Can a property specified by the user alter the default that we'll put
      # on a new object?) -- rjbs, 2016-06-02
      #
      # More importantly, this needs to be called less often.  Originally, we
      # called this once per ix_create and then re-used the results.  We can't
      # do that now that we have a record type (elsewhere) that has to create
      # $n external resources per row.  Ideally(?), we should have
      # ix_default_properties return generators as values.  I'm going to hold
      # off on that until I write the generator to use an iterator that can do
      # $n creates at once, then spool them out, then make $n more, for maximum
      # minimalness. -- rjbs, 2016-06-07
      $rclass->ix_default_properties($ctx)->%*,
    );

    my $this = $to_create->{$id};

    my ($properties, $property_error);
    my $ok = eval {
      ($properties, $property_error) = $self->_ix_check_user_properties(
        $ctx,
        $this,
        \%is_user_prop,
        \%default_properties,
        $prop_info,
      );

      1;
    };

    unless ($ok) {
      my $error = $@;
      $result{not_created}{$id}
        = $error->$_DOES('Ix::Error')
        ? $error
        : $ctx->internal_error("error validating" => { error => $error });
      next TO_CREATE;
    }

    if (%$property_error) {
      $result{not_created}{$id} = $ctx->error(invalidProperties => {
        description => "invalid property values",
        propertyErrors => $property_error,
      });
      next TO_CREATE;
    }

    my %rec = (
      %$properties,

      datasetId => $datasetId,
      modSeqCreated => $next_state,
      modSeqChanged => $next_state,
    );

    if (my $error = $rclass->ix_create_check($ctx, \%rec)) {
      $result{not_created}{$id} = $error;
      next TO_CREATE;
    }

    my $row = eval {
      $ctx->schema->txn_do(sub {
        my $created = $self->create(\%rec);
        $ctx->log_created_id($type_key, $id, $created->id);
        return $created;
      });
    };

    if ($row) {
      my %is_virtual = map {;
        $_ => 1
      } $rclass->ix_virtual_property_names;

      my %created = map {;
        $_ => $row->$_
      } grep {;
        ! $is_virtual{$_}
      } $rclass->ix_property_names;

      # We must return as part of the create response any data that
      # we've added or changed
      my @changed = grep {;
           ! exists $this->{$_}
        || ($this->{$_} // '') ne ($created{$_} // '')
      } keys %created;

      $result{created}{$id} = {
        id => $row->id,
        %created{ @changed },
      };
    } else {
      my $exception = $@;

      my $error;

      if (! $exception->$_DOES('Ix::Error')) {
        $error = $rclass->ix_create_error($ctx, $exception);

        $error ||= $ctx->error(
          'invalidRecord', { description => "could not create" },
          "database rejected creation", { db_error => $exception },
        );
      } else {
        $error = $exception;
      }

      $result{not_created}{$id} = $error;
    }
  }

  $self->_ix_wash_rows([ values $result{created}->%* ]);

  return \%result;
}

sub _ix_check_user_properties (
  $self, $ctx, $rec, $is_user_prop, $defaults, $prop_info
) {
  my %properties;
  my %property_error;

  my %date_fields = map {; $_ => 1 }
                    grep {; ($prop_info->{$_}{data_type} // '') eq 'datetime' }
                    keys %$prop_info;

  # Dedupe
  my %props = map { $_ => 1 } keys %{ $defaults // {} }, keys %$rec;

  PROP: for my $prop (keys %props) {
    my ($value, $is_default);

    if (exists $rec->{$prop}) {
      ($value, $is_default) = ($rec->{$prop}, 0);
    } elsif ($defaults && exists $defaults->{$prop}) {
      ($value, $is_default) = ($defaults->{$prop}, 1);
    }

    my $info  = $prop_info->{$prop};

    # XXX Do we need ix_hidden anymore now that there is a col/prop
    # distinction? -- rjbs, 2016-07-27
    if (! $info || (! $is_default && $info->{ix_hidden}) ) {
      $property_error{$prop} = "unknown property";
      next PROP;
    }

    # User input cannot set internal fields
    if (! $is_default && ! $is_user_prop->{$prop}) {
      $property_error{$prop} = "property cannot be set by client";
      next PROP;
    }

    if (
      $value->$_isa('JSON::PP::Boolean') || $value->$_isa('JSON::XS::Boolean')
    ) {
      $value = $value ? 1 : 0;
    }

    if (ref $value && ! ($value->$_isa('DateTime') && $date_fields{$prop})) {
      $property_error{$prop} = "invalid property value";
      next PROP;
    }

    if (
      # Probably we can intuit this from foreign keys or relationships?
      (my $xref_type = $info->{xref_to})
      &&
      $value && $value =~ /\A#(.+)\z/
    ) {
      if (my $xref = $ctx->get_created_id($xref_type, "$1")) {
        $value = $xref;
      } else {
        $property_error{$prop} = "can't resolve creation id";
        next PROP;
      }
    }

    if ($date_fields{$prop}) {
      # Already a DateTime object (checked above)?
      if (defined $value) {
        if (! ref $value) {
          if (my $dt = parsedate($value)) {
            # great, it's already valid
            $value = $dt;
          } else {
            $property_error{$prop} = "invalid date value";
            next PROP;
          }
        } elsif (! $value->$_isa('Ix::DateTime')) {
          # Make sure inserts/updates contain zulu format. This isn't strictly
          # necessary since we configure our SQL sessions to be UTC anyway,
          # but can't hurt and consistency is good.
          #
          # We know that the object must be a DateTime because we ensure,
          # above, that only DateTime objects are permitted.
          $value = Ix::DateTime->from_epoch(
            epoch => $value->epoch,
            time_zone => 'UTC'
          );
        }
      }
    }

    # These checks should probably always be last
    if (my $validator = $info->{validator}) {
      if (my $error = $validator->($value)) {
        $property_error{$prop} = $error;
        next PROP;
      }
    }

    $properties{$prop} = $value;
  }

  # $defaults being defined means we're doing a create, not an update
  my %is_virtual = map {; $_ => 1 } $self->_ix_rclass->ix_virtual_property_names;

  # Creating? Check all fields that the user could/should pass in.
  # Updating? Only check what they did pass in
  my $to_check = $defaults ? $is_user_prop : \%properties;

  for my $prop (
    grep { ! defined $properties{$_} }
    keys %$to_check
  ) {
    next if $is_virtual{$prop};
    next if $prop_info->{$prop}->{is_optional};

    if (exists $properties{$prop}) {
      $property_error{$prop} //=
        "null value given for field requiring a $prop_info->{$prop}{data_type}";
    } else {
      # Required but has a 'default_value' (and didn't use ix_default_values?)
      # Ugh, okay. (Looking at you 'id') -- alh, 2016-08-16
      next if $prop_info->{$prop}->{default_value};

      $property_error{$prop} //= "no value given for required field";
    }
  }

  return (\%properties, \%property_error);
}

sub _ix_wash_rows ($self, $rows) {
  my $rclass = $self->_ix_rclass;
  my $info   = $rclass->ix_property_info;

  my %by_type;
  for my $key (keys %$info) {
    my $type = $info->{$key}{data_type};
    push $by_type{$type}->@*, $key if $type;
  }

  my $true  = JSON::true();
  my $false = JSON::false();

  for my $row (@$rows) {
    for my $key ($by_type{integer}->@*) {
      $row->{$key} = 0 + $row->{$key} if defined $row->{$key};
    }

    for my $key ($by_type{string}->@*) {
      $row->{$key} = "$row->{$key}" if defined $row->{$key};
    }

    for my $key ($by_type{boolean}->@*) {
      $row->{$key} = $row->{$key} ? $true : $false if defined $row->{$key};
    }

    for my $key ($by_type{datetime}->@*) {
      if ($row->{$key}) {
        # Doesn't already look like an RFC3339 Zulu date?
        if ($row->{$key} !~ /Z/) {
          $row->{$key} = parsepgdate($row->{$key});
        }
      }
    }
  }

  $rclass->_ix_wash_rows($rows) if $rclass->can('_ix_wash_rows');

  return;
}

my $UPDATED = 1;
my $SKIPPED = 2;

sub ix_update ($self, $ctx, $to_update) {
  my $datasetId = $ctx->datasetId;

  my $rclass = $self->_ix_rclass;

  my %result;

  my $type_key   = $rclass->ix_type_key;
  my $next_state = $ctx->state->next_state_for($type_key);

  my @updated;

  my %is_user_prop = map {; $_ => 1 } $rclass->ix_mutable_properties($ctx);
  my $prop_info = $rclass->ix_property_info;

  state $bad_idstr = idstr();

  UPDATE: for my $id (keys $to_update->%*) {
    my $row;

    unless ($bad_idstr->($id)) {
      $row = $self->find({
        id => $id,
        datasetId   => $datasetId,
        dateDeleted => undef,
      });
    }

    unless ($row) {
      $result{not_updated}{$id} = $ctx->error(notFound => {
        description => "no such record found",
      });
      next UPDATE;
    }

    my ($user_prop, $property_error) = $self->_ix_check_user_properties(
      $ctx,
      $to_update->{$id},
      \%is_user_prop,
      undef,
      $prop_info,
    );

    if (%$property_error) {
      $result{not_updated}{$id} = $ctx->error(invalidProperties => {
        description => "invalid property values",
        propertyErrors => $property_error,
      });
      next UPDATE;
    }

    if (my $error = $rclass->ix_update_check($ctx, $row, $user_prop)) {
      $result{not_updated}{$id} = $error;
      next UPDATE;
    }

    my $ok = eval {
      $ctx->schema->txn_do(sub {
        $row->set_inflated_columns({ %$user_prop });
        return $SKIPPED unless $row->get_dirty_columns;

        $row->update({ modSeqChanged => $next_state });
        return $UPDATED;
      });
    };

    if ($ok) {
      push @updated, $id;
      $result{actual_updates}++ if $ok == $UPDATED;
    } else {
      my $exception = $@;

      my $error;

      if (! $exception->$_DOES('Ix::Error')) {
        $error = $rclass->ix_update_error($ctx, $exception);

        $error ||= $ctx->error(
          'invalidRecord', { description => "could not update" },
          "database rejected update", { db_error => $exception },
        );
      } else {
        $error = $exception;
      }

      $result{not_updated}{$id} = $error;
    }
  }

  $result{updated} = \@updated;

  return \%result;
}

sub ix_destroy ($self, $ctx, $to_destroy) {
  my $datasetId = $ctx->datasetId;

  my $rclass = $self->_ix_rclass;

  my $type_key   = $rclass->ix_type_key;
  my $next_state = $ctx->state->next_state_for($type_key);

  my %result;

  my @destroyed;

  state $bad_idstr = idstr();

  DESTROY: for my $id ($to_destroy->@*) {
    my $row;

    unless ($bad_idstr->($id)) {
      $row = $self->search({
        id => $id,
        datasetId => $datasetId,
        dateDeleted => undef,
      })->first;
    }

    unless ($row) {
      $result{not_destroyed}{$id} = $ctx->error(notFound => {
        description => "no such record found",
      });
      next DESTROY;
    }

    if (my $error = $rclass->ix_destroy_check($ctx, $row)) {
      $result{not_destroyed}{$id} = $error;
      next DESTROY;
    }

    my $ok = eval {
      $ctx->schema->txn_do(sub {
        $row->update({
          modSeqChanged => $next_state,
          dateDeleted   => Ix::DateTime->now,
        });
        return 1;
      });
    };

    if ($ok) {
      push @destroyed, $id;
    } else {
      $result{not_destroyed}{$id} = $ctx->internal_error(
        "database rejected delete", { db_error => "$@" },
      );
    }
  }

  $result{destroyed} = \@destroyed;

  return \%result;
}

sub ix_set ($self, $ctx, $arg = {}) {
  my $datasetId = $ctx->datasetId;

  my $rclass   = $self->_ix_rclass;
  my $type_key = $rclass->ix_type_key;
  my $schema   = $self->result_source->schema;

  my $state = $ctx->state;
  my $curr_state = $rclass->ix_state_string($state);

  my %expected_arg = map {; $_ => 1 } qw(ifInState create update destroy);
  if (my @unknown = grep {; ! $expected_arg{$_} } keys %$arg) {
    return $ctx->error('invalidArguments' => {
      description => "unknown arguments passed",
      unknownArguments => \@unknown,
    });
  }

  # TODO validate everything

  if (($arg->{ifInState} // $curr_state) ne $curr_state) {
    return $ctx->error('stateMismatch');
  }

  # Let consumers decide if they allow create/update/destroy or not
  if (my $err = $rclass->ix_set_check($ctx, $arg)) {
    return $err;
  }

  my %result;

  if ($arg->{create}) {
    my $create_result = $self->ix_create($ctx, $arg->{create});

    $result{created}     = $create_result->{created};
    $result{not_created} = $create_result->{not_created};

    $state->ensure_state_bumped($type_key) if keys $result{created}->%*;
  }

  if ($arg->{update}) {
    my $update_result = $self->ix_update($ctx, $arg->{update});

    $result{updated} = $update_result->{updated};
    $result{not_updated} = $update_result->{not_updated};
    $state->ensure_state_bumped($type_key)
      if $result{updated} && $result{updated}->@* && $update_result->{actual_updates};
  }

  if ($arg->{destroy}) {
    my $destroy_result = $self->ix_destroy($ctx, $arg->{destroy});

    $result{destroyed} = $destroy_result->{destroyed};
    $result{not_destroyed} = $destroy_result->{not_destroyed};
    $state->ensure_state_bumped($type_key) if $result{destroyed} && $result{destroyed}->@*;
  }

  $ctx->state->_save_states;

  return Ix::Result::FoosSet->new({
    result_type => "${type_key}Set",
    old_state => $curr_state,
    new_state => $rclass->ix_state_string($state),
    %result,
  });
}

1;
