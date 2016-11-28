use 5.20.0;
use warnings;
package Ix::DBIC::ResultSet;

use parent 'DBIx::Class::ResultSet';

use experimental qw(signatures postderef);

use Ix::Util qw(parsedate parsepgdate differ);
use JSON (); # XXX temporary?  for false() -- rjbs, 2016-02-22
use List::MoreUtils qw(uniq);
use Safe::Isa;
use Ix::Validators qw(idstr);
use Unicode::Normalize qw(NFC);
use Try::Tiny;

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
  my $rclass = $self->_ix_rclass;
  $ctx = $ctx->with_account($rclass->ix_account_type, $arg->{accountId});

  my $accountId = $ctx->accountId;

  # XXX This is crap. -- rjbs, 2016-04-29
  $arg = $rclass->ix_preprocess_get_arg($ctx, $arg)
    if $rclass->can('ix_preprocess_get_arg');

  # unknown argument checking
  my %allowed_arg = map {; $_ => 1 }
    ( qw(accountId properties ids), $rclass->ix_extra_get_args );
  if (my @unknown = grep {; ! $allowed_arg{$_} } keys %$arg) {
    return $ctx->error("invalidArguments" => {
      description => "unknown arguments to get",
      unknownArguments => \@unknown,
    });
  }

  my $ids   = $arg->{ids};

  my $prop_info = $rclass->ix_property_info;
  my %is_prop   = map  {; $_ => 1 }
                  (keys %$prop_info),
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

  state $bad_idstr = Ix::Validators::idstr();
  my @ids;

  if ($ids) {
    @ids = grep {; ! $bad_idstr->($_) } @$ids;
  }

  my %is_virtual = map {; $_ => 1 } $rclass->ix_virtual_property_names;
  my @rows = $self->search(
    {
      accountId => $accountId,
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
  my $rclass = $self->_ix_rclass;
  $ctx = $ctx->with_account($rclass->ix_account_type, $arg->{accountId});

  my $accountId = $ctx->accountId;

  my $since = $arg->{sinceState};

  return $ctx->error(invalidArguments => { description => "no sinceState given" })
    unless defined $since;

  my $limit = $arg->{maxChanges};
  if (defined $limit && ( $limit !~ /^[0-9]+\z/ || $limit == 0 )) {
    return $ctx->error(invalidArguments => { description => "invalid maxChanges" });
  }

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
      description => "client cache must be reconstructed"
    })->throw
  }

  my ($x_update_cond, $x_update_attr) = $rclass->ix_update_extra_search($ctx, {
    since => $since,
  });

  my $state_string_field = $rclass->ix_update_state_string_field;

  my $search = $self->search(
    {
      'me.accountId'     => $accountId,
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

sub ix_purge ($self, $ctx, $arg = {}) {
  my $rclass = $self->_ix_rclass;
  $ctx = $ctx->with_account($rclass->ix_account_type, $arg->{accountId});

  my $accountId = $ctx->accountId;

  my $type_key = $rclass->ix_type_key;

  my $since = Ix::DateTime->from_epoch(epoch => time - 86400 * 7);

  my $rs = $self->search({
    accountId   => $accountId,
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
  my $accountId = $ctx->accountId;

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

      accountId => $accountId,
      modSeqCreated => $next_state,
      modSeqChanged => $next_state,
    );

    if (my $error = $rclass->ix_create_check($ctx, \%rec)) {
      $result{not_created}{$id} = $error;
      next TO_CREATE;
    }

    my ($row, $error) = try {
      $ctx->schema->txn_do(sub {
        my $created = $self->create(\%rec);

        # Fire a hook inside this transaction if necessary
        $rclass->ix_created($ctx, $created);

        return $created;
      });
    } catch {
      my $exception = $_;

      return (undef, $exception) if $exception->$_DOES('Ix::Error');

      my ($row, $error) = $rclass->ix_create_error(
        $ctx,
        $exception,
        { input => $this, rec => \%rec },
      );

      unless ($row or $error) {
        return (
          undef,
          $ctx->error(
            'invalidRecord', { description => "could not create" },
            "database rejected creation", { db_error => $exception },
          ),
        );
      }

      return ($row, $error);
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

      $ctx->log_created_id($type_key, $id, $row->id);
    } else {
      $result{not_created}{$id} = $error;
    }
  }

  # Let rclasses fill in extra details or modify data in create response
  $rclass->ix_postprocess_create($ctx, [ values $result{created}->%* ]);

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

    my $info = $prop_info->{$prop};

    unless ($info) {
      $property_error{$prop} = "unknown property";
      next PROP;
    }

    # User input cannot set internal fields
    if (! $is_default && ! $is_user_prop->{$prop}) {
      $property_error{$prop} = "property cannot be set by client";
      next PROP;
    }

    # Only allow refs for specific types
    if (ref $value) {
      my $ok;

      $ok = 1 if $date_fields{$prop} && $value->$_isa('DateTime');

      $ok ||= 1 if ($prop_info->{$prop}{data_type} // '') eq 'boolean'
                && (
                     $value->$_isa('JSON::PP::Boolean')
                  || $value->$_isa('JSON::XS::Boolean')
                );

      unless ($ok) {
        $property_error{$prop} = "invalid property value";
        next PROP;
      }
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

    if (
      $value->$_isa('JSON::PP::Boolean') || $value->$_isa('JSON::XS::Boolean')
    ) {
      $value = $value ? 1 : 0;
    }

    if (defined $value && $info->{data_type} eq 'string') {
      $value = NFC($value);
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

our $UPDATED = 1;
our $SKIPPED = 2;

sub ix_update ($self, $ctx, $to_update) {
  my $accountId = $ctx->accountId;

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
        accountId   => $accountId,
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

    my ($ok, $error) = try {
      $ctx->schema->txn_do(sub {
        $row->set_inflated_columns({ %$user_prop });
        return $SKIPPED unless $row->get_dirty_columns;

        $row->update({ modSeqChanged => $next_state });

        # Fire a hook inside this transaction if necessary
        $rclass->ix_updated($ctx, $row);

        return $UPDATED;
      });
    } catch {
      my $exception = $_;

      return (undef, $exception) if $exception->$_DOES('Ix::Error');

      my ($ok, $error) = $rclass->ix_update_error(
        $ctx,
        $exception,
        { input => $to_update->{$id}, row => $row }
      );

      unless ($ok or $error) {
        return (
          undef,
          $ctx->error(
            'invalidRecord', { description => "could not update" },
            "database rejected update", { db_error => $exception },
          ),
        );
      }

      return ($ok, $error);
    };

    if ($ok) {
      push @updated, $id;
      $result{actual_updates}++ if $ok == $UPDATED;
    } else {
      $result{not_updated}{$id} = $error;
    }
  }

  $result{updated} = \@updated;

  # Let rclasses do something with the updated ids if they like
  $rclass->ix_postprocess_update($ctx, $result{updated});

  return \%result;
}

sub ix_destroy ($self, $ctx, $to_destroy) {
  my $accountId = $ctx->accountId;

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
        accountId => $accountId,
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

          # Null this out making any unique constraints unblocked for
          # a new create (since null is never == null in postgres)
          isActive      => undef,
        });

        # Fire a hook inside this transaction if necessary
        $rclass->ix_destroyed($ctx, $row);

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

  # Let rclasses do something with the destroyed ids if they like
  $rclass->ix_postprocess_destroy($ctx, $result{destroyed});

  return \%result;
}

sub ix_set ($self, $ctx, $arg = {}) {
  my $rclass = $self->_ix_rclass;

  $ctx = $ctx->with_account($rclass->ix_account_type, $arg->{accountId});
  my $accountId = $ctx->accountId;

  my $type_key = $rclass->ix_type_key;
  my $schema   = $self->result_source->schema;

  my $state = $ctx->state;
  my $curr_state = $rclass->ix_state_string($state);

  my %expected_arg  = map {; $_ => 1 }
                      qw(accountId ifInState create update destroy);
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

  my $ret = [ Ix::Result::FoosSet->new({
    result_type => "${type_key}Set",
    old_state => $curr_state,
    new_state => $rclass->ix_state_string($state),
    %result,
  }) ];

  # This hook lets rclasses inject more responses into the result if they
  # need to
  $rclass->ix_postprocess_set($ctx, $ret)
    if $rclass->can('ix_postprocess_set');

  return @$ret;
}

sub ix_get_list ($self, $ctx, $arg = {}) {
  my $rclass = $self->_ix_rclass;
  $ctx = $ctx->with_account($rclass->ix_account_type, $arg->{accountId});

  my $key = $rclass->ix_type_key;
  my $key1 = $rclass->ix_type_key_singular;
  my $fetch_arg = "fetch\u$key";

  my $schema = $ctx->schema;

  my $limit = $arg->{limit} // 500;
  $limit = 500 if $limit > 500 && $arg->{$fetch_arg};

  my $search = $self->_get_list_search_args($ctx, $arg);
  $search->{filter}{'me.isActive'} = 1;

  if (my $error = $rclass->ix_get_list_check($ctx, $arg, $search)) {
    return $error;
  }

  my $search_page = $search->{rs}->search(
    $search->{filter},
    {
      $search->{sort}->%*,
      rows      => $limit,
      offset    => $arg->{position} // 0,
      result_class => 'DBIx::Class::ResultClass::HashRefInflator',
    },
  );

  my @ids = $search_page->get_column('id')->all;

  my $hms = "" . $schema->resultset('State')->find({
    accountId => $ctx->accountId,
    type      => $key,
  })->highestModSeq;

  my @res = $ctx->result("${key1}List" => {
    filter       => $arg->{filter},
    sort         => $arg->{sort},
    state        => $hms,
    total        => $search->{rs}->search($search->{filter})->count,
    position     => $arg->{position} // 0,
    "${key1}Ids" => [ map {; "$_" } @ids ],

    canCalculateUpdates => \1,
  });

  if ($arg->{$fetch_arg}) {
    push @res, $self->ix_get($ctx, { ids => \@ids });

    my $res_list = $res[-1]->result_arguments->{list};

    # Any other fetch* args?
    for my $field (keys $rclass->ix_get_list_fetchable_map->%*) {
      if ($arg->{$field}) {
        my $fetchable = $rclass->ix_get_list_fetchable_map->{$field};

        my @ids = map {; "$_->{$fetchable->{field}}" } $res_list->@*;

        push @res, $schema->resultset($fetchable->{result_set})->ix_get(
          $ctx,
          { ids => \@ids },
        );
      }
    }
  }

  return @res;
}

sub ix_get_list_updates ($self, $ctx, $arg = {}) {
  my $rclass = $self->_ix_rclass;
  $ctx = $ctx->with_account($rclass->ix_account_type, $arg->{accountId});

  my $key = $rclass->ix_type_key;
  my $key1 = $rclass->ix_type_key_singular;

  my $schema = $ctx->schema;

  my $since_state = $arg->{sinceState};

  return $ctx->error(invalidArguments => { description => "no sinceState given" })
    unless defined $since_state;

  my $state = $schema->resultset('State')->find({
    accountId => $ctx->accountId,
    type      => $key,
  });

  if (
    $since_state > $state->highestModSeq
    or
    $since_state < $state->lowestModSeq
  ) {
    return $ctx->error(cannotCalculateChanges => {});
  }

  my $search = $self->_get_list_search_args($ctx, $arg);

  if (my $error = $rclass->ix_get_list_updates_check($ctx, $arg, $search)) {
    return $error;
  }

  my $total = $search->{rs}->search($search->{filter})
                           ->search({ isActive => 1 })->count;

  if ($arg->{sinceState} == $state->highestModSeq) {
    # Nothing changed!  But we still promise to return the total,
    # unfortunately, so we get it. -- rjbs, 2016-04-13
    return $ctx->result("${key1}ListUpdates" => {
      filter => $arg->{filter},
      sort   => $arg->{sort},
      oldState => $since_state,
      newState => $since_state,
      total    => $total,
      removed  => [ ],
      added    => [ ],
    });
  }

  my $filter_map = $rclass->ix_get_list_filter_map;
  my %required = map {;
    $_ => $arg->{filter}{$_}
  } grep {;
    $filter_map->{$_}->{required}
  } keys %$filter_map;

  # XXX: stupid, gross, blah -- rjbs, 2016-04-13
  my @entities = $search->{rs}->search(
    \%required,
    $search->{sort}
  )->all;

  my $i = 0;
  my @added;
  my @removed;

  for my $entity (@entities) {
    my $is_new     = $entity->modSeqCreated > $since_state;
    my $is_changed = $entity->modSeqChanged > $since_state;
    my $is_removed = $entity->dateDeleted;

    unless ($is_removed) {
      FILTER: for my $filter (keys $arg->{filter}->%*) {
        if (differ($entity->$filter, $arg->{filter}{$filter})) {
          $is_removed = 1;
          last FILTER;
        }
      }
    }

    my $was_removed = $entity->dateDeleted && ! $is_changed;

    if ($is_removed && ! $is_new && ! $was_removed) {
      push @removed, "" . $entity->id;
    } elsif (! $is_removed && $is_new) {
      push @added, { index => $i, "${key1}Id" => "" . $entity->id };
    } elsif (! $is_removed && $is_changed) {
      push @removed, "" . $entity->id;
      push @added, { index => $i, "${key1}Id" => "" . $entity->id };
    }

    $i++ unless $is_removed;
  }

  return $ctx->result("${key1}ListUpdates" => {
    filter => $arg->{filter},
    sort   => $arg->{sort},
    oldState => "" . $since_state,
    newState => "" . $state->highestModSeq,
    total    => $total,
    removed  => \@removed,
    added    => \@added,
  });
}

sub _get_list_search_args ($self, $ctx, $arg) {
  my $rclass = $self->_ix_rclass;

  my %search;

  $search{rs} = $self->search({ 'me.accountId' => $ctx->accountId });

  my %bad_filter;

  my $filter_map = $rclass->ix_get_list_filter_map;

  FILTER: for my $field (keys $arg->{filter}->%*) {
    if (!$filter_map->{$field}) {
      $bad_filter{$field} = 'unknown filter field';
      next FILTER;
    }
    my $sql_name = $field;
    unless ($sql_name =~ /\./) {
      $sql_name = "me.$sql_name"; # me.<...>
    }

    my $val = defined $arg->{filter}{$field}
                ? $arg->{filter}{$field} . ""
                : undef;
    $search{filter}{$sql_name} = $val;
  }

  for my $field (grep {; $filter_map->{$_}->{required} } keys %$filter_map) {
    unless (exists $arg->{filter}->{$field}) {
      $bad_filter{$field} = 'required filter missing';
    }
  }

  my @sort;
  my %bad_sort;

  my $sort_map = $rclass->ix_get_list_sort_map;

  SORT: for my $sort ($arg->{sort}->@*) {
    my ($field, $order, $extra) = split /\s+/, $sort, 3;
    if (! $sort_map->{$field}) {
      $bad_sort{$sort} = 'unknown sort field';
      next SORT;
    }

    if (! $order) {
      $bad_sort{$sort} = 'invalid sort format: missing sort order';
      next SORT;
    }

    if ($extra) {
      $bad_sort{$sort} = 'invalid sort format: expected exactly two arguments';
      next SORT;
    }

    if ($order ne 'asc' && $order ne 'desc') {
      $bad_sort{$sort} = "invalid sort format: sort order must be 'asc' or 'desc'";
      next SORT;
    }

    push @sort, { "-$order" => $sort_map->{$field}{sort_by} || $field };
  }

  # We need to be consistently ordered on multiple requests.  This will
  # ensure that we are. -- rjbs, 2016-05-13
  push @sort, "me.id";

  if (%bad_filter || %bad_sort) {
    $ctx->error(invalidArguments => {
      description => "Invalid arguments",
      ( %bad_filter ? ( invalidFilters => \%bad_filter ) : () ),
      ( %bad_sort   ? ( invalidSorts   => \%bad_sort   ) : () ),
    })->throw;
  }

  $search{sort} = {
    order_by => \@sort,
    ( $rclass->ix_get_list_joins ? ( join => [ $rclass->ix_get_list_joins ] ) : () ),
  };

  return \%search;
}

1;
