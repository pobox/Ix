use 5.20.0;
package Ix::Processor;

use Moose::Role;
use experimental qw(signatures postderef);

use Safe::Isa;
use Try::Tiny;
use Time::HiRes qw(gettimeofday tv_interval);

use namespace::autoclean;

requires 'handler_for';

around handler_for => sub ($orig, $self, $method, @rest) {
  my $handler = $self->$orig($method, @rest);
  return $handler if $handler;

  my $h = $self->_dbic_handlers;
  return $h->{$method} if exists $h->{$method};

  return;
};

requires 'file_exception_report';

requires 'schema_class';

requires 'connect_info';

sub schema_connection ($self) {
  $self->schema_class->connect(
    $self->connect_info,
    {
      on_connect_do  => "SET TIMEZONE TO 'UTC'",
      auto_savepoint => 1,
      quote_names    => 1,
    },
  );
}

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
      my $key  = $rclass->ix_type_key;
      my $key1 = $rclass->ix_type_key_singular;

      $handler{"get\u$key"} = sub ($self, $ctx, $arg = {}) {
        $ctx->schema->resultset($moniker)->ix_get($ctx, $arg);
      };

      $handler{"get\u${key1}Updates"} = sub ($self, $ctx, $arg = {}) {
        $ctx->schema->resultset($moniker)->ix_get_updates($ctx, $arg);
      };

      $handler{"set\u$key"} = sub ($self, $ctx, $arg) {
        $ctx->schema->resultset($moniker)->ix_set($ctx, $arg);
      };

    }

    return \%handler;
  }
);

# It is tempting to wrap this in a transaction.  Consider the case where a
# method does not return an Ix::Result, so we can't map it into the final
# result set.  That's going to throw an exception, now.  We could catch it and
# report "garbledResponse" as an error, so that the rest of the methods may
# execute, but it indicates a fundamental brokenness of the underlying system,
# and perhaps the entire request should be discarded.  If we do that without a
# response, though, the client is not knowing about changes that have been
# affected.  With an all-encompassing transaction in play, though, the client
# can be given a single "itBroke" error, with all changes rolled back.
#
# This may be needed anyway, since entire requests are executed with
# transactional isolation! -- rjbs, 2016-02-11

sub process_request ($self, $ctx, $calls) {
  my @results;

  $ctx->schema->txn_do(sub {
    my $call_start;

    CALL: for my $call (@$calls) {
      # On one hand, I am tempted to disallow ambiguous cids here.  On the other
      # hand, the spec does not. -- rjbs, 2016-02-11
      $call_start = [ gettimeofday ];

      my ($method, $arg, $cid) = @$call;

      my $handler = $self->handler_for( $method );

      unless ($handler) {
        push @results, [ error => { type => 'unknownMethod' }, $cid ];
        next CALL;
      }

      my @rv = try {
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
        local $_ = $rv[$i];
        push @results, $_->$_DOES('Ix::Result')
                     ? [ $_->result_type, $_->result_arguments, $cid ]
                     : [ error => { type => 'garbledResponse' }, $cid ];

        if ($results[-1][0] eq 'error' && $i < $#rv) {
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

    $ctx->state->_save_states;
  });

  return \@results;
}

1;
