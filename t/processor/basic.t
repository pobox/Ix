use 5.20.0;
use warnings;
use experimental qw(signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::Schema;
use Test::Deep;
use Test::More;
use Safe::Isa;

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
    [
      getCookieUpdates => {
        sinceState => 2,
        fetchRecords => \1,
        fetchRecordProperties => [ qw(type) ]
      },
      'a',
    ],
  ]);

  cmp_deeply(
    $res,
    [
      [ cookieUpdates => ignore(), 'a' ],
      [
        cookies => {
          notFound => undef,
          state => 8,
          list  => [
            { id => $account{cookies}{4}, type => 'samoa',   }, # baked_at => 1455319240 },
            { id => $account{cookies}{5}, type => 'tim tam', }, # baked_at => 1455310000 },
            { id => $account{cookies}{6}, type => 'immortal', }, # baked_at => 1455310000 },
          ],
        },
        'a',
      ],
    ],
    "a getFoos call backed by the database",
  ) or diag explain($res);
}

{
  my $res = $ctx->process_request([
    [ setCookies => { ifInState => 3, destroy => [ $account{cookies}{4} ] }, 'a' ],
  ]);

  is_deeply(
    $res,
    [
      [ error => { type => 'stateMismatch' }, 'a' ],
    ],
    "setCookies respects ifInState",
  ) or diag explain($res);
}

my @created_ids;
{
  my $res = $ctx->process_request([
    [
      setCookies => {
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
        cookiesSet => superhashof({
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
    "we can create cookies with setCookies",
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
      superhashof({ isActive => 1, dateDestroyed => undef, id => $account{cookies}{1}, type => 'half-eaten tim-tam', delicious => 'no', }),
      superhashof({ isActive => 1, dateDestroyed => undef, id => $account{cookies}{2}, type => 'oreo', delicious => 'yes', }),
      superhashof({ isActive => bool(0), dateDestroyed => re(qr/\A[0-9]{4}-/), id => $account{cookies}{4}, type => 'samoa', delicious => 'yes', }),
      superhashof({ isActive => 1, dateDestroyed => undef, id => $account{cookies}{5}, type => 'tim tam', delicious => 'yes', }),
      superhashof({ isActive => 1, dateDestroyed => undef, id => $account{cookies}{6}, type => 'immortal', delicious => 'yes', }),
      superhashof({ isActive => 1, dateDestroyed => undef, id => any(@created_ids), type => any(qw(shortbread anzac)), delicious => any(qw(yes no)), }),
      superhashof({ isActive => 1, dateDestroyed => undef, id => any(@created_ids), type => any(qw(shortbread anzac)), delicious => any(qw(yes no)), }),
    ],
    "the db matches our expectations",
  ) or diag explain(\@rows);

  my $state = $ctx->schema->resultset('State')->search({
    accountId => $account{accounts}{rjbs},
    type => 'cookies',
  })->first;

  is($state->highestModSeq, 9, "state ended got updated just once");
}

{
  my $res = $ctx->process_request([
    [ getCookieUpdates => { sinceState => 8 }, 'a' ],
  ]);

  cmp_deeply(
    $res,
    [
      [
        cookieUpdates => {
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
      [ getCookieUpdates => { sinceState => 999 }, 'a' ],
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
      [ getCookieUpdates => { sinceState => 0 }, 'a' ],
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
    [ getCookies => { ids => [ $account{cookies}{1}, @created_ids ] }, 'a' ],
  ]);

  my $res = $ctx->process_request([
    [ getCookieUpdates => { sinceState => 8, fetchRecords => 1 }, 'a' ],
  ]);

  cmp_deeply(
    $res,
    [
      [
        cookieUpdates => {
          oldState => 8,
          newState => 9,
          hasMoreUpdates => bool(0),
          changed  => bag($account{cookies}{1}, @created_ids),
          removed  => bag($account{cookies}{4}),
        },
        'a',
      ],
      [
        cookies => {
          $get_res->[0][1]->%*,
          list => bag( $get_res->[0][1]{list}->@* ),
        },
        'a',
      ]
    ],
    "updates can be got (with implicit fetch)",
  ) or diag explain($res);
}

{
  my $res = $ctx->process_request([
    [
      setCakes => {
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
        cakesSet => superhashof({
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
      setCookies => {
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
        cookiesSet => superhashof({
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
    type => 'cookies',
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
      setCookies => {
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
        cookiesSet => superhashof({
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
    "setCookies handles objects properly",
  ) or diag explain($res);

  my %c_to_id = map {;
    $_ => $res->[0][1]{created}{$_}{id}
  } keys %{ $res->[0][1]{created} };

  # Verify we got the right dates
  $res = $ctx->process_request([
    [
      getCookieUpdates => {
        sinceState => 9,
        fetchRecords => \1,
        fetchRecordProperties => [ qw(type baked_at) ]
      }, 'a',
    ],
  ]);

  cmp_deeply(
    $res,
    [
      [ cookieUpdates => ignore(), 'a' ],
      [
        cookies => {
          notFound => undef,
          state => 10,
          list  => set(
            { id => $c_to_id{yellow}, type => 'yellow', baked_at => ignore() },
            { id => $c_to_id{red}, type => 'red', baked_at => ignore() },
          ),
        },
        'a',
      ],
    ],
    "a getFoos call backed by the database",
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
      setCookies => {
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
        cookiesSet => superhashof({
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
    "setCookies handles objects properly",
  ) or diag explain($res);

  # Verify we updated to the new past
  $res = $ctx->process_request([
    [
      getCookieUpdates => {
        sinceState => 10,
        fetchRecords => \1,
        fetchRecordProperties => [ qw(type baked_at) ]
      }, 'a',
    ],
  ]);

  cmp_deeply(
    $res,
    [
      [ cookieUpdates => ignore(), 'a' ],
      [
        cookies => {
          notFound => undef,
          state => 11,
          list  => [
            { id => $c_to_id{yellow}, type => 'yellow', baked_at => ignore() },
          ],
        },
        'a',
      ],
    ],
    "a getFoos call backed by the database",
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
      setCookies => {
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
        cookiesSet => superhashof({
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
    "we can create cookies with setCookies",
  ) or diag explain($res);

}

done_testing;
