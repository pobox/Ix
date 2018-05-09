use 5.20.0;
use warnings;
use experimental qw(lexical_subs signatures postderef);

package Bakesale::Test {
  use File::Temp qw(tempdir);
  use Ix::Util qw(ix_new_id);

  sub new_test_app_and_tester ($self) {
    require JMAP::Tester;
    require LWP::Protocol::PSGI;

    my $app = Bakesale::App->new({
      transaction_log_enabled => 1,
    });

    state $n;
    $n++;
    LWP::Protocol::PSGI->register($app->to_app, host => 'bakesale.local:' . $n);
    my $jmap_tester = JMAP::Tester->new({
      api_uri => "http://bakesale.local:$n/jmap",
    });

    return ($app, $jmap_tester);
  }

  my %TEST_DBS;
  END { $_->cleanup for $TEST_DBS{$$}->@*; }

  sub test_schema_connect_info {
    require Test::PgMonger;
    my $db = Test::PgMonger->new->create_database({
      extra_sql_statements => [
        "CREATE EXTENSION IF NOT EXISTS citext;",
      ],
    });
    push $TEST_DBS{$$}->@*, $db;

    my $schema = Bakesale->new({
      connect_info => [ $db->connect_info ],
    })->schema_connection;

    $schema->deploy;

    return [ $db->connect_info ];
  }

  sub load_single_user ($self, $schema) {
    my $user_rs = $schema->resultset('User');

    my $user1 = $user_rs->create({
      accountId => ix_new_id(),
      username  => 'testadmin',
      status    => 'active',
      modSeqCreated => 1,
      modSeqChanged => 1,
    });

    $user1 = $user_rs->single({ id => $user1->id });

    $user1->ix_create_base_state;

    return ($user1->id, $user1->accountId);
  }

  sub load_trivial_account ($self, $schema) {
    my sub modseq ($x) { return (modSeqCreated => $x, modSeqChanged => $x) }

    my $user_rs = $schema->resultset('User');

    my $user1 = $user_rs->create({
      accountId => ix_new_id(),
      username  => 'rjbs',
      status    => 'active',
      modseq(1)
    });

    $user1 = $user_rs->single({ id => $user1->id });

    $user1->ix_create_base_state;

    my $user2 = $user_rs->create({
      accountId => ix_new_id(),
      username  => 'neilj',
      status    => 'active',
      modseq(1)
    });

    $user2 = $user_rs->single({ id => $user2->id });

    $user2->ix_create_base_state;

    my $user3 = $user_rs->create({
      accountId => ix_new_id(),
      username  => 'alh',
      status    => 'active',
      modseq(1)
    });

    $user3 = $user_rs->single({ id => $user3->id });

    $user3->ix_create_base_state;

    my $a1 = $user1->accountId;
    my $a2 = $user2->accountId;

    my @cookies = $schema->resultset('Cookie')->populate([
      { accountId => $a1, modseq(1), type => 'tim tam',
        baked_at => '2016-01-01T12:34:56Z', expires_at => '2016-01-03:T12:34:56Z', delicious => 'yes', batch => 1, },
      { accountId => $a1, modseq(1), type => 'oreo',
        baked_at => '2016-01-02T23:45:60Z', expires_at => '2016-01-04T23:45:60Z', delicious => 'yes', batch => 1, },
      { accountId => $a2, modseq(1), type => 'thin mint',
        baked_at => '2016-01-23T01:02:03Z', expires_at => '2016-01-25T01:02:03Z', delicious => 'yes', batch => 1, },
      { accountId => $a1, modseq(3), type => 'samoa',
        baked_at => '2016-02-01T12:00:01Z', expires_at => '2016-02-03:t12:00:01Z', delicious => 'yes', batch => 1, },
      { accountId => $a1, modseq(8), type => 'tim tam',
        baked_at => '2016-02-09T09:09:09Z', expires_at => '2016-02-11T09:09:09Z', delicious => 'yes', batch => 1, },
      { accountId => $a1, modseq(8), type => 'immortal',
        baked_at => '2016-02-10T09:09:09Z', expires_at => '2016-02-11T09:09:09Z', delicious => 'yes', batch => 1, },
    ]);

    my @recipes = $schema->resultset('CakeRecipe')->populate([
      {
        modseq(1),
        accountId    => $a1,
        type         => 'seven-layer',
        avg_review   => 91,
        is_delicious =>  1,
        sku          => '10203',
      },
    ]);

    $schema->resultset('State')->search({
      accountId => $a1, type => 'Cookie',
    })->update({ highestModSeq => 8 });

    $schema->resultset('State')->search({
      accountId => $a2, type => 'Cookie',
    })->update({ highestModSeq => 1 });

    $schema->resultset('State')->search({
      accountId => $a1, type => 'User',
    })->update({ highestModSeq => 1 });

    $schema->resultset('State')->search({
      accountId => $a1, type => 'User',
    })->update({ highestModSeq => 1 });

    return {
      accounts => { rjbs => $a1, neilj => $a2, alh => $user3->accountId, },
      users    => { rjbs => $user1->id, neilj => $user2->id, alh => $user3->id, },
      recipes  => { 1 => $recipes[0]->id },
      cookies  => { map {; ($_+1) => $cookies[$_]->id } keys @cookies },
    };
  }
}

package Bakesale {
  use Moose;
  with 'Ix::Processor::JMAP';

  use HTTP::Throwable::JSONFactory qw(http_throw);

  use Bakesale::Context;
  use Data::GUID qw(guid_string);
  use Ix::Validators qw( enum integer record );

  use experimental qw(signatures postderef);
  use namespace::autoclean;

  sub exceptions;
  has exceptions => (
    lazy => 1,
    traits => [ 'Array' ],
    handles => {
      'exceptions'       => 'elements',
      'clear_exceptions' => 'clear',
      'add_exception'    => 'push',
     },
    default => sub { [] },
  );

  sub file_exception_report ($self, $ctx, $exception) {
    Carp::cluck( "EXCEPTION!! $exception" ) unless $ENV{QUIET_BAKESALE};
    $self->add_exception($exception);
    return guid_string();
  }

  sub connect_info;
  has connect_info => (
    lazy    => 1,
    traits  => [ 'Array' ],
    handles => { connect_info => 'elements' },
    default => sub {
      Bakesale::Test->test_schema_connect_info;
    },
  );

  sub database_defaults {
    return (
      "SET LOCK_TIMEOUT TO '2s'",
    );
  }

  sub get_context ($self, $arg) {
    Bakesale::Context->new({
      userId    => $arg->{userId},
      schema    => $arg->{schema} // $self->schema_connection,
      processor => $self,
    });
  }

  sub get_system_context ($self, $arg = {}) {
    Bakesale::Context::System->new({
      schema    => $arg->{schema} // $self->schema_connection,
      processor => $self,
    });
  }

  sub context_from_plack_request ($self, $req, $arg = {}) {
    if (my $user_id = $req->cookies->{bakesaleUserId}) {
      $user_id =~ s/"(.*)"/$1/;

      if ($ENV{BAD_ID} && $user_id eq $ENV{BAD_ID}) {
        http_throw(Gone => {
          payload => { error => "bad auth" },
        });
      }

      return $self->get_context({
        schema => $arg->{schema},
        userId => $user_id,
      });
    }

    http_throw('Gone');
  }

  sub schema_class { 'Bakesale::Schema' }

  sub handler_for ($self, $method) {
    return 'result_count'  if $method eq 'countResults';
    return 'count_chars'   if $method eq 'countChars';
    return 'pie_type_list' if $method eq 'pieTypes';
    return 'bake_pies'     if $method eq 'bakePies';
    return 'validate_args' if $method eq 'validateArguments';
    return 'echo'          if $method eq 'echo';
    return;
  }

  sub result_count ($self, $ctx, $arg) {
    my $sc = $ctx->results_so_far;

    my $s_count = $sc->sentences;
    my $p_count = $sc->paragraphs;

    return Ix::Result::Generic->new({
      result_type       => 'resultCount',
      result_arguments  => { sentences => $s_count, paragraphs => $p_count },
    });
  }

  sub count_chars ($self, $ctx, $arg) {
    my $string = $arg->{string};
    my $length = length $string;
    return Ix::Result::Generic->new({
      result_type       => 'charCount',
      result_arguments => {
        string => $string,
        length => $length,
      },
    });
  }

  sub pie_type_list ($self, $ctx, $arg = {}) {
    my $only_tasty = delete local $arg->{tasty};
    return $ctx->error('invalidArguments') if keys %$arg;

    my @flavors = qw(pumpkin apple pecan);
    push @flavors, qw(cherry eel) unless $only_tasty;

    return Bakesale::PieTypes->new({ flavors => \@flavors });
  }

  sub validate_args ($self, $ctx, $arg = {}) {
    state $argchk = record({
      required => [ qw(needful)  ],
      optional => {
        whatever => integer(-1, 1),
        subrec   => record({
          required => { color => enum([ qw(red green blue) ]) },
          optional => [ 'saturation' ],
        }),
      },
      throw    => 1,
    });

    $argchk->($arg);

    return Ix::Result::Generic->new({
      result_type       => 'argumentsValidated',
      result_arguments  => {},
    });
  }

  sub echo ($self, $ctx, $arg) {
    return Ix::Result::Generic->new({
      result_type       => 'echoEcho',
      result_arguments  => { args => $arg->{echo} },
    });
  }

  sub bake_pies ($self, $ctx, $arg = {}) {
    return $ctx->error("invalidArguments")
      unless $arg->{pieTypes} && $arg->{pieTypes}->@*;

    my %is_flavor = map {; $_ => 1 }
                    $self->pie_type_list($ctx, { tasty => $arg->{tasty} })->flavors;

    my @rv;
    for my $type ($arg->{pieTypes}->@*) {
      if ($is_flavor{$type}) {
        push @rv, Bakesale::Pie->new({ flavor => $type });
      } else {
        push @rv, $ctx->error(noRecipe => { requestedPie => $type })
      }
    }

    return @rv;
  }

  __PACKAGE__->meta->make_immutable;
  1;
}

package Bakesale::PieTypes {
  use Moose;
  with 'Ix::Result';

  use experimental qw(signatures postderef);
  use namespace::autoclean;

  has flavors => (
    traits   => [ 'Array' ],
    handles  => { flavors => 'elements' },
    required => 1,
  );

  sub result_type { 'pieTypes' }

  sub result_arguments ($self) {
    return {
      flavors => [ $self->flavors ],
    };
  }

  __PACKAGE__->meta->make_immutable;
  1;
}

package Bakesale::Pie {
  use Moose;

  with 'Ix::Result';

  use experimental qw(signatures postderef);
  use namespace::autoclean;

  has flavor     => (is => 'ro', required => 1);
  has bake_order => (is => 'ro', default => sub { state $i; ++$i });

  sub result_type { 'pie' }
  sub result_arguments ($self) {
    return { flavor => $self->flavor, bakeOrder => $self->bake_order };
  }
}

1;
