use 5.20.0;
package Ix::Processor::JMAP;
# ABSTRACT: do stuff with JMAP requests

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

=head1 OVERVIEW

This is a Moose role designed to make JMAP processors (the kind of processor
used by an L<Ix::App::JMAP>) easy to write. It automatically adds method
handlers for the standard JMAP methods (/get, /set, /changes, and maybe /query
and /queryChanges) which are built from your L<Ix::DBIC::Result> classes. See
the documentation there for more details.

=cut

=method handler_for($method_name)

Implementations are required to provide this method, but it can be a stub.
This method is passed a JMAP method name (like 'Core/echo') and should return
either undef or a coderef, which is later called with the parameters C<$self>, an
C<Ix::Context> object, and the method's arguments as a hashref.

If your C<handler_for> method returns undef, the processor will look first for
handlers in your C<Ix::DBIC::Result> classes' C<ix_published_method_map>
methods, and then for its standard JMAP handlers (/get, /set, /changes, and
maybe /query and /queryChanges).

Take, for example the following rclass:

    package MyApp::Schema::Result::Cookie;
    use base qw/DBIx::Class::Core/;
    __PACKAGE__->load_components(qw/+Ix::DBIC::Result/);

    sub ix_query_enabled { 0 }

    sub published_method_map {
      return { 'Cookie/bake' => 'cookie_bake' };
    }

If your JMAP processor provides only a stub C<handler_for>, you will
automatically get handlers for Cookie/bake (provided by the rclass itself),
plus Cookie/get, Cookie/set, and Cookie/changes (provided by this role). If
your rclass was C<ix_query_enabled>, you would also get Cookie/query and
Cookie/queryChanges.

You can provide a more extensive C<handler_for> inside your processor to enable
JMAP methods I<not> implemented by C<Ix::DBIC::Result> rclasses. This processor
handles the methods 'Spline/reticulate' and 'Flux/capacitate' in addition to
all of the methods defined by its rclasses:

    package MyApp::JMAP::Processor;
    use Moose;
    with 'Ix::Processor::JMAP';

    my %other_handlers = (
      'Spline/reticulate' => sub ($self, $ctx, $arg) {
        return $ctx->result('Spline/reticulate', { reticulationCount => 42 });
      },

      'Flux/capacitate' => sub ($self, $ctx, $arg) {
        return $ctx->error('forbidden', { reason => 'if you have to ask' });
      }
    );

    sub handler_for ($self, $name) {
      return $other_handlers{$name};
    }

=cut

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
        $ctx->schema->resultset($moniker)->ix_changes($ctx, $arg);
      };

      $handler{"$key/set"} = sub ($self, $ctx, $arg) {
        $ctx->schema->resultset($moniker)->ix_set($ctx, $arg);
      };

      if ($rclass->ix_query_enabled) {
        $handler{"$key/query"} = sub ($self, $ctx, $arg) {
          $ctx->schema->resultset($moniker)->ix_query($ctx, $arg);
        };
        $handler{"$key/queryChanges"} = sub ($self, $ctx, $arg) {
          $ctx->schema->resultset($moniker)->ix_query_changes($ctx, $arg);
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

=method expand_backrefs($ctx, $arg, $meta = {})

This method is used internally to expand JMAP result references. The context
object keeps a list of results accumulated so far, so that this method can
search through them and resolve the ResultReference object into something we
can actually call.

=cut

sub expand_backrefs ($self, $ctx, $arg, $meta_arg = {}) {
  return unless my @backref_keys = map  {; s/^#// ? $_ : () } keys %$arg;

  my %skip_cid = map {; $_ => 1 } ($meta_arg->{skip_cids} // [])->@*;

  my sub throw_ref_error ($desc) {
    Ix::Error::Generic->new({
      error_type  => 'resultReference',
      properties  => {
        description => $desc,
      },
    })->throw;
  }

  if (my @duplicated = grep {; exists $arg->{$_} } @backref_keys) {
    throw_ref_error( "arguments present as both ResultReference and not: "
                   .  join(q{, }, @duplicated));
  }

  my @sentences = $ctx->results_so_far->sentences;

  KEY: for my $key (@backref_keys) {
    my $ref = $arg->{"#$key"};

    unless ( _HASH0($ref)
          && 3 == grep {; defined $ref->{$_} } qw(resultOf name path)
    ) {
      throw_ref_error("malformed ResultReference");
    }

    # With multicalls, we may sometimes need to do partial expansions.  This
    # lets us expand only some parts of the present backrefs.
    next if $skip_cid{ $ref->{resultOf} };

    delete $arg->{"#$key"};

    my ($sentence) = grep {; $_->client_id eq $ref->{resultOf} } @sentences;

    unless ($sentence) {
      throw_ref_error("no result for client id $ref->{resultOf}");
    }

    unless ($sentence->name eq $ref->{name}) {
      throw_ref_error(
        "first result for client id $ref->{resultOf} is not $ref->{name} but "
        . $sentence->name,
      );
    }

    my ($result, $error) = Ix::Util::resolve_modified_jpointer(
      $ref->{path},
      $sentence->arguments,
    );

    if ($error) {
      throw_ref_error("error with path: $error");
    }

    $arg->{$key} = ref $result ? Storable::dclone($result) : $result;
  }

  return;
}

=method handle_calls($ctx, $calls, $arg = {})

This is the where the main work of the processor happens. It checks the
arguments for well-formedness, calls C<optimize_calls>, then begins
processing. To do so, it walks the list of C<$calls>, calling C<handler_for>
to get each method name, expands backrefs as necessary, then calls the handler
to process each call individually.  The handlers return L<Ix::Result> objects,
which are accumulated by an C<Ix::JMAP::SentenceCollection> object. When all
of the calls have been processed, this checks for and reports any errors, then
returns the sentence collection.

=cut

sub handle_calls ($self, $ctx, $calls, $arg = {}) {
  $self->_sanity_check_calls($calls, {
    add_missing_client_ids => ! $arg->{no_implicit_client_ids}
  });

  $self->optimize_calls($ctx, $calls);

  my $call_start;
  my $was_known_call;

  my $sc = Ix::JMAP::SentenceCollection->new;
  local $ctx->root_context->{result_accumulator} = $sc;

  CALL: for my $call (@$calls) {
    $call_start = [ gettimeofday ];
    $was_known_call = 1;

    if ($call->$_DOES('Ix::Multicall')) {
      # Returns [ [ $item, $cid ], ... ]
      my $pairs = $call->execute($ctx);

      Carp::confess("non-Ix::Result in result list")
        if grep {; ! $_->[0]->$_DOES('Ix::Result') } @$pairs;

      $sc->add_items($pairs);

      next CALL;
    }

    # On one hand, I am tempted to disallow ambiguous cids here.  On the other
    # hand, the spec does not. -- rjbs, 2016-02-11
    my ($method, $arg, $cid) = @$call;

    my $handler = $self->handler_for( $method );

    unless ($handler) {
      $was_known_call = 0;
      $sc->add_items([
        [
          Ix::Error::Generic->new({ error_type  => 'unknownMethod' }),
          $cid,
        ],
      ]);

      next CALL;
    }

    my @rv = try {
      $self->expand_backrefs($ctx, $arg);

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

    RV: for my $i (0 .. $#rv) {
      my $item = $rv[$i];

      Carp::confess("non-Ix::Result in result list: $item")
        unless $item->$_DOES('Ix::Result');

      $sc->add_items([[ $item, $cid ]]);

      if ($item->does('Ix::Error') && $i < $#rv) {
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

    # XXX - We still want to record call info for multicalls!
    #       -- alh, 2019-06-26
    my $ident = $call->$_DOES('Ix::Multicall')
              ? $call->call_ident
              : $call->[0];

    $ctx->record_call_info($ident, {
      elapsed_seconds => tv_interval($call_start, $call_end),
      was_known_call  => $was_known_call,
    });
  }

  return $sc;
}

=method optimize_calls($ctx, $calls)

By default this is a no-op; this is called before actually processing any of
the method calls. Implementations may modify C<$calls> in-place, if they want
to muck about with anything to make processing faster.

=cut

sub optimize_calls {}

=method process_request($ctx, $calls)

This is a wrapper around C<handle_calls> that returns its results as a set of
triples (i.e., an arrayref) rather than as a sentence collection.

=cut

sub process_request ($self, $ctx, $calls) {
  my $sc = $self->handle_calls($ctx, $calls);

  return $sc->as_triples;
}

1;
