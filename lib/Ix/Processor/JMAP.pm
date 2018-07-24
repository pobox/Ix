use 5.20.0;
package Ix::Processor::JMAP;

use Moose::Role;
use experimental qw(lexical_subs signatures postderef);

use Params::Util qw(_HASH0);
use Safe::Isa;
use Storable ();
use Try::Tiny;
use Time::HiRes qw(gettimeofday tv_interval);

use namespace::autoclean;

use Ix::JMAP::SentenceCollection;

with 'Ix::Processor';

requires 'handler_for';

around handler_for => sub ($orig, $self, $method, @rest) {
  my $handler = $self->$orig($method, @rest);
  return $handler if $handler;

  my $h = $self->_dbic_handlers;
  return $h->{$method} if exists $h->{$method};

  return;
};

has _dbic_handlers => (
  is   => 'ro',
  lazy => 1,
  init_arg => undef,
  default => sub {
    my ($self) = @_;

    my %handler;

    my $source_reg = $self->schema_class->source_registrations;
    for my $moniker (keys %$source_reg) {
      my $rclass = $source_reg->{$moniker}->result_class;
      next unless $rclass->isa('Ix::DBIC::Result');

      if (
        $rclass->can('ix_published_method_map')
        &&
        (my $method_map = $rclass->ix_published_method_map)
      ) {
        for (keys %$method_map) {
          my $method = $method_map->{$_};
          $handler{$_} = sub ($self, $ctx, $arg = {}) {
            $rclass->$method($ctx, $arg);
          };
        }
      }

      my $key = $rclass->ix_type_key;

      $handler{"$key/get"} = sub ($self, $ctx, $arg = {}) {
        $ctx->schema->resultset($moniker)->ix_get($ctx, $arg);
      };

      $handler{"$key/changes"} = sub ($self, $ctx, $arg = {}) {
        $ctx->schema->resultset($moniker)->ix_get_updates($ctx, $arg);
      };

      $handler{"$key/set"} = sub ($self, $ctx, $arg) {
        $ctx->schema->resultset($moniker)->ix_set($ctx, $arg);
      };

      if ($rclass->ix_get_list_enabled) {
        $handler{"$key/query"} = sub ($self, $ctx, $arg) {
          $ctx->schema->resultset($moniker)->ix_get_list($ctx, $arg);
        };
        $handler{"$key/queryChanges"} = sub ($self, $ctx, $arg) {
          $ctx->schema->resultset($moniker)->ix_get_list_updates($ctx, $arg);
        };
      }
    }

    return \%handler;
  }
);

sub _sanity_check_calls ($self, $calls, $arg) {
  # We should, in the future, add a bunch of error checking up front and reject
  # badly-formed requests.  For now, this is a placeholder, except for its
  # client id fixups. -- rjbs, 2018-01-05

  my %saw_cid;

  # Won't happen.  Won't happen.  Won't happen... -- rjbs, 2018-01-05
  Carp::confess("too many method calls") if @$calls > 5_000;

  for my $call (@$calls) {
    if (not defined $call->[2]) {
      if ($arg->{add_missing_client_ids}) {
        my $next;
        do { $next = "x" . int rand 10_000 } while exists $saw_cid{$next};
        $call->[2] = $next;
      } else {
        Carp::confess("missing client id");
      }
    }
    $saw_cid{$call->[2]} = 1;
  }

  return;
}

sub expand_backrefs ($self, $ctx, $arg) {
  return unless my @backref_keys = map {; s/^#// ? $_ : () } keys %$arg;

  my sub ref_error ($desc) {
    Ix::Error::Generic->new({
      error_type  => 'resultReference',
      properties  => {
        description => $desc,
      },
    });
  }

  if (my @duplicated = grep {; exists $arg->{$_} } @backref_keys) {
    return ref_error( "arguments present as both ResultReference and not: "
                    .  join(q{, }, @duplicated));
  }

  my @sentences = $ctx->results_so_far->sentences;

  for my $key (@backref_keys) {
    my $ref  = delete $arg->{"#$key"};

    unless ( _HASH0($ref)
          && 3 == grep {; defined $ref->{$_} } qw(resultOf name path)
    ) {
      return ref_error("malformed ResultReference");
    }

    my ($sentence) = grep {; $_->client_id eq $ref->{resultOf} } @sentences;

    unless ($sentence) {
      return ref_error("no result for client id $ref->{resultOf}");
    }

    unless ($sentence->name eq $ref->{name}) {
      return ref_error(
        "first result for client id $ref->{resultOf} is not $ref->{name} but "
        . $sentence->name,
      );
    }

    my ($result, $error) = Ix::Util::resolve_modified_jpointer(
      $ref->{path},
      $sentence->arguments,
    );

    if ($error) {
      return ref_error("error with path: $error");
    }

    $arg->{$key} = ref $result ? Storable::dclone($result) : $result;
  }

  return;
}

sub handle_calls ($self, $ctx, $calls, $arg = {}) {
  $self->_sanity_check_calls($calls, {
    add_missing_client_ids => ! $arg->{no_implicit_client_ids}
  });

  my $call_start;

  my $sc = Ix::JMAP::SentenceCollection->new;
  local $ctx->root_context->{result_accumulator} = $sc;

  CALL: for my $call (@$calls) {
    $call_start = [ gettimeofday ];

    # On one hand, I am tempted to disallow ambiguous cids here.  On the other
    # hand, the spec does not. -- rjbs, 2016-02-11
    my ($method, $arg, $cid) = @$call;

    my $handler = $self->handler_for( $method );

    unless ($handler) {
      $sc->add_items([
        [
          Ix::Error::Generic->new({ error_type  => 'unknownMethod' }),
          $cid,
        ],
      ]);

      next CALL;
    }

    my @rv = $self->expand_backrefs($ctx, $arg);

    unless (@rv) {
      @rv = try {
        unless ($ctx->may_call($method, $arg)) {
          return $ctx->error(forbidden => {
            description => "you are not authorized to make this call",
          });
        }

        $self->$handler($ctx, $arg);
      } catch {
        if ($_->$_DOES('Ix::Error')) {
          return $_;
        } else {
          warn $_;
          die $_;
        }
      };
    }

    RV: for my $i (0 .. $#rv) {
      local $_ = $rv[$i];
      my $item
        = $_->$_DOES('Ix::Result')
        ? [ $_, $cid ]
        : [
            Ix::Error::Generic->new({ error_type  => 'garbledResponse' }),
            $cid,
          ];

      $sc->add_items([ $item ]);

      if ($item->[0]->does('Ix::Error') && $i < $#rv) {
        # In this branch, we have a potential return value like:
        # (
        #   [ valid => ... ],
        #   [ error => ... ],
        #   [ valid => ... ],
        # );
        #
        # According to the JMAP specification ("§ Errors"), we shouldn't be
        # getting anything after the error.  So, remove it, but also file an
        # exception report. -- rjbs, 2016-02-11
        #
        # TODO: file internal error report -- rjbs, 2016-02-11
        last RV;
      }
    }
  } continue {
    my $call_end = [ gettimeofday ];

    # Just elapsed time for now
    $ctx->record_call_info($call->[0], {
      elapsed_seconds => tv_interval($call_start, $call_end),
    });
  }

  return $sc;
}

sub process_request ($self, $ctx, $calls) {
  my $sc = $self->handle_calls($ctx, $calls);

  return $sc->as_triples;
}

1;
