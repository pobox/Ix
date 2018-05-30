use 5.20.0;
use warnings;
use experimental qw(signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::Schema;
use Capture::Tiny qw(capture_stderr);
use Test::Deep;
use Test::More;
use Safe::Isa;
use Try::Tiny;

my $no_updates = any({}, undef);

my $Bakesale = Bakesale->new;
\my %account = Bakesale::Test->load_trivial_account($Bakesale->schema_connection);

my $ctx = $Bakesale->get_context({
  userId => $account{users}{rjbs},
});

{
  my $res = $ctx->process_request([
    [ pieTypes => { tasty => 1 }, 'a' ],
    [ pieTypes => { tasty => 0 }, 'b' ],
  ]);

  is_deeply(
    $res,
    [
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] }, 'a' ],
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] }, 'b' ],
    ],
    "the most basic possible call works",
  ) or diag explain($res);
}

{
  my $res = $ctx->process_request([
    [ pieTypes => { tasty => 1 } ],
    [ pieTypes => { tasty => 0 } ],
    [ pieTypes => { tasty => 1 }, 'a' ],
  ]);

  my $ci_re = re(qr/\A x [0-9]{1,4} \z/x);
  cmp_deeply(
    $res,
    [
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] }, $ci_re ],
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] }, $ci_re ],
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] }, 'a' ],
    ],
    "implicit client ids are added as needed",
  ) or diag explain($res);
}

{
  my $res = eval {
    $ctx->handle_calls([
      [ pieTypes => { tasty => 1 } ],
      [ pieTypes => { tasty => 0 } ],
      [ pieTypes => { tasty => 1 }, 'a' ],
    ], { no_implicit_client_ids => 1 })->as_triples;
  };

  my $error = $@;

  like(
    $error,
    qr{missing client id},
    "if unfixed, request without client ids are rejected",
  );
}

{
  my $res = $ctx->process_request([
    [ pieTypes => { tasty => 1 }, 'a' ],
    [ bakePies => { tasty => 1, pieTypes => [ qw(apple eel pecan) ] }, 'b' ],
    [ pieTypes => { tasty => 0 }, 'c' ],
  ]);

  is_deeply(
    $res,
    [
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] }, 'a' ],
      [ pie   => { flavor => 'apple', bakeOrder => 1 }, 'b' ],
      [ error => { type => 'noRecipe', requestedPie => 'eel' }, 'b' ],
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] }, 'c' ],
    ],
    "a call with an error and a multi-value result",
  ) or diag explain($res);
}

{
  my $res = $ctx->process_request([
    [ 'Cookie/changes' => { sinceState => 2 }, 'a' ],
    [
      'Cookie/get' => {
        properties => [ 'type' ],
        '#ids' => {
          resultOf => 'a',
          name => 'Cookie/changes',
          path => '/changed'
        },
      },
      'b',
    ],
  ]);

  cmp_deeply(
    $res,
    [
      [ 'Cookie/changes' => ignore(), 'a' ],
      [
        'Cookie/get' => {
          notFound => undef,
          state => 8,
          list  => [
            { id => $account{cookies}{4}, type => 'samoa',   }, # baked_at => 1455319240 },
            { id => $account{cookies}{5}, type => 'tim tam', }, # baked_at => 1455310000 },
            { id => $account{cookies}{6}, type => 'immortal', }, # baked_at => 1455310000 },
          ],
        },
        'b',
      ],
    ],
    "a Foo/get call backed by the database",
  ) or diag explain($res);
}

{
  my $res = $ctx->process_request([
    [ 'Cookie/set' => { ifInState => 3, destroy => [ $account{cookies}{4} ] }, 'a' ],
  ]);

  is_deeply(
    $res,
    [
      [ error => { type => 'stateMismatch' }, 'a' ],
    ],
    "Cookie/set respects ifInState",
  ) or diag explain($res);
}

my @created_ids;
{
  my $res = $ctx->process_request([
    [
      'Cookie/set' => {
        ifInState => 8,
        create    => {
          yellow => { type => 'shortbread', },
          gold   => { type => 'anzac', delicious => 'no', },
          blue   => {},
        },
        update => {
          $account{cookies}{1} => { type => 'half-eaten tim-tam', delicious => 'no', },
          $account{cookies}{2} => { pretty_delicious => 0 },
        },
        destroy => [ $account{cookies}->@{3,4} ],
      },
      'a'
    ],
  ]);

  cmp_deeply(
    $res,
    [
      [
        'Cookie/set' => superhashof({
          oldState => 8,
          newState => 9,

          created => {
            yellow => { id => ignore(), baked_at => ignore(), expires_at => ignore(), delicious => ignore(), external_id => ignore, batch => ignore() },
            gold   => { id => ignore(), baked_at => ignore(), expires_at => ignore(), external_id => ignore, batch => ignore() },
          },
          notCreated => {
            blue   => superhashof({
              type => 'invalidProperties',
              propertyErrors => { type => 'no value given for required field' }
            }),
          },
          updated => { $account{cookies}{1} => $no_updates },
          notUpdated => {
            $account{cookies}{2} => superhashof({
              type => 'invalidProperties',
              propertyErrors => { pretty_delicious => "unknown property" },
            }),
          },
          destroyed => [ $account{cookies}{4} ],
          notDestroyed => {
            $account{cookies}{3} => superhashof({ type => ignore(), }),
          },
        }),
        'a'
      ],
    ],
    "we can create cookies with Cookie/set",
  ) or diag explain($res);

  @created_ids = map {; $_->{id} } values %{ $res->[0][1]{created} };

  my @rows = $ctx->schema->resultset('Cookie')->search(
    { accountId => $account{accounts}{rjbs} },
    {
      order_by => 'baked_at',
      result_class => 'DBIx::Class::ResultClass::HashRefInflator',
    },
  );

  cmp_deeply(
    \@rows,
    [
      superhashof({ isActive => bool(1), dateDestroyed => undef, id => $account{cookies}{1}, type => 'half-eaten tim-tam', delicious => 'no', }),
      superhashof({ isActive => bool(1), dateDestroyed => undef, id => $account{cookies}{2}, type => 'oreo', delicious => 'yes', }),
      superhashof({ isActive => bool(0), dateDestroyed => re(qr/\A[0-9]{4}-/), id => $account{cookies}{4}, type => 'samoa', delicious => 'yes', }),
      superhashof({ isActive => bool(1), dateDestroyed => undef, id => $account{cookies}{5}, type => 'tim tam', delicious => 'yes', }),
      superhashof({ isActive => bool(1), dateDestroyed => undef, id => $account{cookies}{6}, type => 'immortal', delicious => 'yes', }),
      superhashof({ isActive => bool(1), dateDestroyed => undef, id => any(@created_ids), type => any(qw(shortbread anzac)), delicious => any(qw(yes no)), }),
      superhashof({ isActive => bool(1), dateDestroyed => undef, id => any(@created_ids), type => any(qw(shortbread anzac)), delicious => any(qw(yes no)), }),
    ],
    "the db matches our expectations",
  ) or diag explain(\@rows);

  my $state = $ctx->schema->resultset('State')->search({
    accountId => $account{accounts}{rjbs},
    type => 'Cookie',
  })->first;

  is($state->highestModSeq, 9, "state ended got updated just once");
}

{
  my $res = $ctx->process_request([
    [ 'Cookie/changes' => { sinceState => 8 }, 'a' ],
  ]);

  cmp_deeply(
    $res,
    [
      [
        'Cookie/changes' => {
          oldState => 8,
          newState => 9,
          hasMoreUpdates => bool(0),
          changed  => bag($account{cookies}{1}, @created_ids),
          removed  => bag($account{cookies}{4}),
        },
        'a',
      ],
    ],
    "updates can be got",
  ) or diag explain($res);
}

subtest "invalid sinceState" => sub {
  subtest "too high" => sub {
    my $res = $ctx->process_request([
      [ 'Cookie/changes' => { sinceState => 999 }, 'a' ],
    ]);

    cmp_deeply(
      $res,
      [
        [
          error => superhashof({ type => 'invalidArguments' }),
          'a',
        ],
      ],
      "updates can't be got for invalid sinceState",
    ) or diag explain($res);
  };

  subtest "too low" => sub {
    my $res = $ctx->process_request([
      [ 'Cookie/changes' => { sinceState => -1 }, 'a' ],
    ]);

    cmp_deeply(
      $res,
      [
        [
          error => superhashof({ type => 'cannotCalculateChanges' }),
          'a',
        ],
      ],
      "updates can't be got for invalid sinceState",
    ) or diag explain($res);
  };
};

{
  my $get_res = $ctx->process_request([
    [ 'Cookie/get' => { ids => [ $account{cookies}{1}, @created_ids ] }, 'a' ],
  ]);

  my $res = $ctx->process_request([
    [ 'Cookie/changes' => { sinceState => 8 }, 'a' ],
    [
      'Cookie/get' => {
        '#ids' => {
          resultOf => 'a',
          name => 'Cookie/changes',
          path => '/changed',
        },
      },
      'b',
    ]
  ]);

  cmp_deeply(
    $res,
    [
      [
        'Cookie/changes' => {
          oldState => 8,
          newState => 9,
          hasMoreUpdates => bool(0),
          changed  => bag($account{cookies}{1}, @created_ids),
          removed  => bag($account{cookies}{4}),
        },
        'a',
      ],
      [
        'Cookie/get' => {
          $get_res->[0][1]->%*,
          list => bag( $get_res->[0][1]{list}->@* ),
        },
        'b',
      ]
    ],
    "updates can be got with backrefs",
  ) or diag explain $res;
}

{
  my $res = $ctx->process_request([
    [
      'Cake/set' => {
        ifInState => '0-0',
        create    => {
          yum => { type => 'layered', layer_count => 4, recipeId => $account{recipes}{1} }
        }
      },
      'cake!',
    ],
  ]);

  cmp_deeply(
    $res,
    [
      [
        'Cake/set' => superhashof({
          created => {
            yum => superhashof({ baked_at => ignore() }),
          }
        }),
        'cake!',
      ],
    ],
    "we can bake cakes",
  ) or diag explain($res);
}

{
  my $res = $ctx->process_request([
    [
      'Cookie/set' => {
        ifInState => 9,
        destroy   => [ $account{cookies}{3} ],
        create    => { blue => {} },
        update    => { $account{cookies}{2} => { pretty_delicious => 0 } },
      },
      'poirot'
    ],
  ]);

  cmp_deeply(
    $res,
    [
      [
        'Cookie/set' => superhashof({
          oldState => 9,
          newState => 9,

          notCreated   => { blue => ignore() },
          notUpdated   => { $account{cookies}{2} => ignore() },
          notDestroyed => { $account{cookies}{3} => ignore() },
        }),
        'poirot'
      ],
    ],
    "no state change when no destruction",
  ) or diag explain($res);

  my $state = $ctx->schema->resultset('State')->search({
    accountId => $account{accounts}{rjbs},
    type => 'Cookie',
  })->first;

  is($state->highestModSeq, 9, "no updates, no state change");
}

{
  # Make sure object detection works
  my $past = DateTime->now->subtract(years => 5);
  my $ixdt = $past->clone;
  bless $ixdt, 'Ix::DateTime';
  my $past_str = $ixdt->as_string;

  my $bad = bless {}, 'Brownie';

  my $res = $ctx->process_request([
    [
      'Cookie/set' => {
        ifInState => 9,
        create    => {
          yellow => { type => 'yellow', baked_at => $past },
          red    => { type => 'red', baked_at => $ixdt },
          green  => { type => 'green', baked_at => $bad },
          pink   => { type => $past },
        }
      },
      'a',
    ],
  ]);

  cmp_deeply(
    $res,
    [
      [
        'Cookie/set' => superhashof({
          created => {
            yellow => { id => ignore(), expires_at => ignore(), delicious => ignore(), external_id => ignore, batch => ignore, },
            red    => { id => ignore(), expires_at => ignore(), delicious => ignore(), external_id => ignore, batch => ignore, },
          },
          notCreated => {
            green  => superhashof({
              type => 'invalidProperties',
              propertyErrors => { baked_at => "invalid property value" },
            }),
            pink  => superhashof({
              type => 'invalidProperties',
              propertyErrors => { type => "invalid property value" },
            }),
          },
        }),
        'a',
      ],
    ],
    "Cookie/set handles objects properly",
  ) or diag explain($res);

  my %c_to_id = map {;
    $_ => $res->[0][1]{created}{$_}{id}
  } keys %{ $res->[0][1]{created} };

  # Verify we got the right dates
  $res = $ctx->process_request([
    [ 'Cookie/changes' => { sinceState => 9, }, 'a' ],
    [
      'Cookie/get' => {
        properties => [ qw(type baked_at) ],
        '#ids' => {
          resultOf => 'a',
          name => 'Cookie/changes',
          path => '/changed'
        },
      }, 'b',
    ]
  ]);

  cmp_deeply(
    $res,
    [
      [ 'Cookie/changes' => ignore(), 'a' ],
      [
        'Cookie/get' => {
          notFound => undef,
          state => 10,
          list  => set(
            { id => $c_to_id{yellow}, type => 'yellow', baked_at => ignore() },
            { id => $c_to_id{red}, type => 'red', baked_at => ignore() },
          ),
        },
        'b',
      ],
    ],
    "a Foo/get call backed by the database",
  ) or diag explain($res);

  ok($res->[1][1]{list}[0]{baked_at}->$_isa('DateTime'), 'got a dt object');
  is($res->[1][1]{list}[0]{baked_at}->as_string, $past_str, 'time is right');

  ok($res->[1][1]{list}[1]{baked_at}->$_isa('DateTime'), 'got a dt object');
  is($res->[1][1]{list}[1]{baked_at}->as_string, $past_str, 'time is right');

  $past->add(days => 10);
  $ixdt->add(days => 10);
  $past_str = $ixdt->as_string;

  $res = $ctx->process_request([
    [
      'Cookie/set' => {
        ifInState => 10,
        update    => {
          $c_to_id{yellow} => { type => 'yellow', baked_at => $past },
          $c_to_id{red}    => { type => $past },
        },
      },
      'a',
    ],
  ]);

  cmp_deeply(
    $res,
    [
      [
        'Cookie/set' => superhashof({
          updated => {
            $c_to_id{yellow} => $no_updates,
          },
          notUpdated => {
            $c_to_id{red}  => superhashof({
              type => 'invalidProperties',
              propertyErrors => { type => "invalid property value" },
            }),
          },
        }),
        'a',
      ],
    ],
    "Cookie/set handles objects properly",
  ) or diag explain($res);

  # Verify we updated to the new past
  $res = $ctx->process_request([
    [ 'Cookie/changes' => { sinceState => 10, }, 'a' ],
    [
      'Cookie/get' => {
        properties => [ qw(type baked_at) ],
        '#ids' => {
          resultOf => 'a',
          name => 'Cookie/changes',
          path => '/changed',
        },
      },
      'b',
    ]
  ]);

  cmp_deeply(
    $res,
    [
      [ 'Cookie/changes' => ignore(), 'a' ],
      [
        'Cookie/get' => {
          notFound => undef,
          state => 11,
          list  => [
            { id => $c_to_id{yellow}, type => 'yellow', baked_at => ignore() },
          ],
        },
        'b',
      ],
    ],
    "a Foo/get call backed by the database",
  ) or diag explain($res);

  ok($res->[1][1]{list}[0]{baked_at}->$_isa('DateTime'), 'got a dt object');
  is($res->[1][1]{list}[0]{baked_at}->as_string, $past_str, 'time is right');
}

{
  # Ensure system context can also create entities
  my $account = $account{accounts}{rjbs};
  my $ctx = $Bakesale->get_system_context;

  my $res = $ctx->process_request([
    [
      'Cookie/set' => {
        accountId => $account,
        ifInState => 11,
        create    => {
          yellow => { type => 'shortbread', },
          green => { type => 'what', id => undef, },
        },
        update => {
          $account{cookies}{1} => { type => 'half-eaten sugar' },
        },
      },
      'a'
    ],
  ]);

  cmp_deeply(
    $res,
    [
      [
        'Cookie/set' => superhashof({
          oldState => 11,
          newState => 12,

          created => {
            yellow => { id => ignore(), baked_at => ignore(), expires_at => ignore(), delicious => ignore(), external_id => ignore(), batch => ignore(), },
          },
          updated => { $account{cookies}{1} => $no_updates },
          notCreated => {
            green   => superhashof({
              type => 'invalidProperties',
              propertyErrors => { id => 'invalid id string' }
            }),
          },
        }),
        'a'
      ],
    ],
    "we can create cookies with Cookie/set",
  ) or diag explain($res);
}

{
  # Ensure even after exceptions that our context's state is cleared and
  # not reused
  $ctx = $ctx->with_account('generic' => undef);

  capture_stderr(sub {
    print STDERR "Ignore the next exception report for now..\n";
    my $error = try {
      $ctx->process_request([
        [
          'Cake/set' => { create => [] },
        ],
      ]);

      return;
    } catch {
      return $_;
    };

    ok($error, 'process_request died');
  });

  # Make another call with that ctx, should succeed
  my $cake_res = $ctx->process_request([
    [
      'Cake/set' => {
        create    => {
          yum => { type => 'layered', layer_count => 4, recipeId => $account{recipes}{1} }
        }
      },
      'cake!',
    ],
  ]);

  cmp_deeply(
    $cake_res,
    [
      [
        'Cake/set' => superhashof({
          created => {
            yum => superhashof({ baked_at => ignore() }),
          }
        }),
        'cake!',
      ],
    ],
    "we can bake cakes",
  ) or diag explain($cake_res);
}

{
  # Ensure we actually create transactions in txn_do

  # It turns out that '$ctx->txn_do()' wasn't ever actually
  # creating transactions/save points! ALHSDLFJS:KFJDS:LJFS:LKJ
  # This test starts a transaction, then forces a duplicate
  # key error which would prevent any other statements in our
  # transaction from succeeding if txn_do() wasn't doing its
  # job.
  my $ctx = $Bakesale->get_system_context;

  $ctx = $ctx->with_account('generic' => $account{accounts}{rjbs});

  my $res = $ctx->schema->txn_do(sub {
    $ctx->process_request([
      [ 'User/set' => {
        create => {
          first  => { username => 'kaboom', },
          kaboom => { username => 'kaboom', },
        },
      }, 'a', ],
      [ 'User/set' => {
        create => {
          second => { username => 'second', },
          third =>  { username => 'third',  },
        },
      }, 'b', ],
    ]),
  });

  is(
    keys $res->[0][1]{created}->%*,
    1,
    'created a single user'
  );
  is(
    keys $res->[1][1]{created}->%*,
    2,
    'created 2 users'
  );

  my ($err) = values $res->[0][1]{notCreated}->%*;
  like(
    $err->{description},
    qr/create conflicts/,
    'got duplicate error'
  );
}

subtest "results outside of request" => sub {
  eval { local $ENV{QUIET_BAKESALE} = 1; $ctx->results_so_far };

  my $error = $@;
  like(
    $error,
    qr{tried to inspect},
    "can't call ->results_so_far outside req",
  );
};

done_testing;
