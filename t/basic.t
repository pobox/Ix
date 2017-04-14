use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use JSON::MaybeXS;
use Test::Deep;
use Test::Deep::JType;
use Test::More;
use Unicode::Normalize;
use Ix::Util qw(ix_new_id);

my $no_updates = any({}, undef);

{
  my ($test_env) = Bakesale::Test->new_test_env;
  my ($app, $jmap_tester) = $test_env->@{qw(app tester)};
  \my %account = Bakesale::Test->load_trivial_account(
    $app->processor->schema_connection
  );

  $jmap_tester->_set_cookie('bakesaleUserId', $account{users}{rjbs});

  {
    $app->clear_transaction_log;

    my $res = $jmap_tester->request([
      [ pieTypes => { tasty => 1 } ],
      [ pieTypes => { tasty => 0 } ],
    ]);

    jcmp_deeply(
      $res->sentence(0)->as_pair,
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] } ],
      "first call response: as expected",
    );

    jcmp_deeply(
      $res->paragraph(1)->single->as_pair,
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] } ],
      "second call response group: one item, as expected",
    );

    my @xacts = $app->drain_transaction_log;
    is(@xacts, 1, "we log transactions (at least when testing)");
  }

  {
    my $res = $jmap_tester->request([
      [ pieTypes => { tasty => 1 } ],
      [ bakePies => { tasty => 1, pieTypes => [ qw(apple eel pecan) ] } ],
      [ pieTypes => { tasty => 0 } ],
    ]);

    my ($pie1, $bake, $pie2) = $res->assert_n_paragraphs(3);

    cmp_deeply(
      $jmap_tester->strip_json_types( $pie1->as_pairs ),
      [
        [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] } ],
      ],
      "pieTypes call 1 reply: as expected",
    );

    jcmp_deeply(
      $bake->as_pairs,
      [
        [ pie   => { flavor => 'apple', bakeOrder => jnum(1) } ],
        [ error => { type => 'noRecipe', requestedPie => jstr('eel') } ],
      ],
      "bakePies call reply: as expected",
    );

    cmp_deeply(
      $jmap_tester->strip_json_types( $pie2->as_pairs ),
      [
        [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] } ],
      ],
      "pieTypes call 2 reply: as expected",
    );
  }

  {
    my $res = $jmap_tester->request([
      [ getCookies => {
          ids   => [ 1 ],
          tasty => 1,
          kakes => \1,
      } ],
    ]);

    cmp_deeply(
      $res->as_stripped_pairs,
      [
        [
          error => {
            type => 'invalidArguments',
            description => "unknown arguments to get",
            unknownArguments => bag(qw(kakes)),
          },
        ],
      ],
      "you can't just pass random new args to getFoos",
    );
  }

  {
    my $res = $jmap_tester->request([
      [ getCookieUpdates => {
          sinceState   => 2,
          fetchRecords => \1,
          fetchRecordProperties => [ qw(type) ],
        }
      ],
    ]);

    isa_ok(
      $res->as_struct->[1][1]{list}[0]{id},
      'JSON::Typist::String',
      "the returned id",
    ) or diag(explain($res->as_struct));

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [ cookieUpdates => ignore() ],
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
        ],
      ],
      "a getFoos call backed by the database",
    );
  }

  {
    my @ids = values $account{cookies}->%*;
    my $does_not_exist = ix_new_id();

    my $res = $jmap_tester->request([
      [
        getCookies => {
          ids        => [ $account{cookies}{4}, $does_not_exist ],
          properties => [ qw(type) ]
        }
      ],
    ]);

    isa_ok(
      $res->as_struct->[0][1]{list}[0]{id},
      'JSON::Typist::String',
      "we return ids as strings",
    );

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookies => {
            notFound => [ $does_not_exist ],
            state => 8,
            list  => [
              { id => $account{cookies}{4}, type => "samoa" }, # baked_at => 1455319240 },
            ],
          },
        ],
      ],
      "a getFoos call with notFound entries",
    );
  }

  {
    my $res = $jmap_tester->request([
      [ getCakes => { } ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          error => {
            type => 'invalidArguments',
            description => "required parameter 'ids' not present",
          }
        ]
      ],
      "a getCakes call without 'ids' argument",
    );
  }

  {
    my $res = $jmap_tester->request([
      [ setCookies => { ifInState => 3, destroy => [ 4 ] } ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [ error => { type => 'stateMismatch' } ],
      ],
      "setCookies respects ifInState",
    );
  }

  my @created_ids;

  {
    my $res = $jmap_tester->request([
      [
        setCookies => {
          ifInState => 8,
          create    => {
            yellow => { type => 'shortbread', baked_at => undef },
            gold   => { type => 'anzac' },
            blue   => {},
            orange => { type => 'apple', pretty_delicious => 1 },
          },
          update => {
            $account{cookies}{1} => { type => 'half-eaten tim-tam' },
            $account{cookies}{2} => { pretty_delicious => 0, id => 999 },
          },
          destroy => [ $account{cookies}->@{3, 4, 6} ],
        },
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookiesSet => superhashof({
            oldState => 8,
            newState => 9,

            created => {
              yellow => { id => ignore(), expires_at => ignore(), delicious => ignore(), external_id => ignore, batch => ignore, }, # no baked_at, because not default
              gold   => { id => ignore(), expires_at => ignore, baked_at => ignore(), delicious => ignore(), external_id => ignore, batch => ignore, },
            },
            notCreated => {
              blue   => superhashof({
                type => 'invalidProperties',
                propertyErrors => { type => 'no value given for required field' }
              }),
              orange => superhashof({
                type => 'invalidProperties',
                propertyErrors => { pretty_delicious => "unknown property" },
              }),
            },
            updated => { $account{cookies}{1} => $no_updates },
            notUpdated => {
              $account{cookies}{2} => superhashof({
                type => 'invalidProperties',
                propertyErrors => {
                  pretty_delicious => "unknown property",
                  id => re(qr/cannot be set/),
                },
              }),
            },
            destroyed => [ $account{cookies}{4} ],
            notDestroyed => {
              $account{cookies}{3} => superhashof({ type => ignore() }),
              $account{cookies}{6} => superhashof({ description => 'You can\'t destroy an immortal cookie!'}),
            },
          }),
        ],
      ],
      "we can create cookies with setCookies",
    ) or diag(explain($jmap_tester->strip_json_types( $res->as_pairs )));

    my $set = $res->single_sentence->as_set;

    is($set->old_state, 8, "old state is 8");
    is($set->new_state, 9, "new state is 9");

    cmp_deeply(
      [ sort $set->created_creation_ids ],
      [ qw(gold yellow) ],
      "created the things we expected",
    );

    my $struct = $jmap_tester->strip_json_types( $set->arguments );
    @created_ids = map {; $struct->{created}{$_}{id} }
                   $set->created_creation_ids;

    # Check ix_update_check
    $res = $jmap_tester->request([
      [
        setCookies => {
          ifInState => 9,
          update => {
            $account{cookies}{1} => { type => 'tim-tam' },
            $account{cookies}{2} => { baked_at => '2301-01-01T12:12:12Z' },
          },
        },
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookiesSet => superhashof({
            notUpdated => {
              $account{cookies}{1} => superhashof({
                'type' => 'partyFoul',
                'description' => 'You can\'t pretend you haven\'t eaten a part of that coookie!',
              }),
              $account{cookies}{2} => superhashof({
                'type' => 'timeSpaceContinuumFoul',
                'description' => 'You can\'t claim to have baked a cookie in the future',
              }),
            },
          }),
        ],
      ],
      "ix_update_check called during update with row values",
    ) or diag(explain($jmap_tester->strip_json_types( $res->as_pairs )));
  }

  {
    my $res = $jmap_tester->request([
      [ getCookieUpdates => { sinceState => 8 } ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookieUpdates => {
            oldState => 8,
            newState => 9,
            hasMoreUpdates => bool(0),
            changed  => bag($account{cookies}{1}, @created_ids),
            removed  => bag($account{cookies}{4}),
          },
        ],
      ],
      "updates can be got",
    ) or diag explain( $res->as_pairs );
  }

  subtest "invalid sinceState" => sub {
    subtest "too high" => sub {
      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => 999 } ],
      ]);

      cmp_deeply(
        $jmap_tester->strip_json_types( $res->single_sentence->as_pair ),
        [ error => superhashof({ type => 'invalidArguments' }) ],
        "updates can't be got for invalid sinceState",
      ) or diag explain($res);
    };

    subtest "too low" => sub {
      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => -1 } ],
      ]);

      cmp_deeply(
        $jmap_tester->strip_json_types( $res->single_sentence->as_pair ),
        [ error => superhashof({ type => 'cannotCalculateChanges' }), ],
        "updates can't be got for invalid sinceState",
      ) or diag explain($res);
    };
  };

  {
    my $get_res = $jmap_tester->request([
      [ getCookies => { ids => [ $account{cookies}{1}, @created_ids ] } ],
    ]);

    my $res = $jmap_tester->request([
      [ getCookieUpdates => { sinceState => 8, fetchRecords => 1 } ],
    ]);

    my $get_payloads = $jmap_tester->strip_json_types(
      $get_res->single_sentence->arguments
    );

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookieUpdates => {
            oldState => 8,
            newState => 9,
            hasMoreUpdates => bool(0),
            changed  => bag($account{cookies}{1}, @created_ids),
            removed  => bag($account{cookies}{4}),
          },
        ],
        [
          cookies => {
            $get_payloads->%*,
            list => bag( $get_payloads->{list}->@* ),
          },
        ],
      ],
      "updates can be got (with implicit fetch)",
    ) or diag explain( $jmap_tester->strip_json_types( $res->as_pairs ) );
  }

  {
    my $res = $jmap_tester->request([
      [
        setCakes => {
          ifInState => '0-0',
          create    => {
            yum => { type => 'layered', layer_count => 4, recipeId => $account{recipes}{1} },
            yow => { type => 'croquembouche', layer_count => 99, recipeId => $account{recipes}{1} }
          }
        },
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cakesSet => superhashof({
            created => {
              yum => superhashof({ baked_at => ignore() }),
            },
            notCreated => {
              yow => superhashof({
                type => 'invalidProperties',
                propertyErrors => { layer_count => re(qr/above max/) },
              }),
            },
          }),
        ],
      ],
      "we can bake cakes",
    ) or diag explain( $jmap_tester->strip_json_types( $res->as_pairs ) );
  }

  subtest "passing in a boolean" => sub {
    my $res = $jmap_tester->request([
      [
        setCakeRecipes => {
          create => {
            boat => {
              type          => 'cake boat',
              avg_review    => 0,
              is_delicious  => \0,
            }
          },
        },
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cakeRecipesSet => superhashof({
            created => {
              boat => { id => ignore(), sku => re(qr/\A[0-9]{5}\z/), },
            }
          }),
        ],
      ],
      "made an object with a boolean property value",
    ) or note(explain($res->as_pairs));

    my $id = $res->single_sentence->as_set->created_id('boat');

    my $get = $jmap_tester->request([
      [ getCakeRecipes => { ids => [ "$id" ] } ]
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $get->as_pairs ),
      [
        [
          cakeRecipes => superhashof({
            list => [ superhashof({ id => "$id", is_delicious => bool(0) }) ],
          }),
        ],
      ],
      "created with the right truthiness",
    ) or note(explain($res->as_pairs));

    # Can't use something that looks like a boolean
    $res = $jmap_tester->request([
      [
        setCakeRecipes => {
          create => {
            boat => {
              type          => 'cake boat',
              avg_review    => 0,
              is_delicious  => 0,
            }
          },
        },
      ],
    ]);

    my $err = $res->paragraph(0)
                  ->single('cakeRecipesSet')
                  ->as_set
                  ->create_errors;

    cmp_deeply(
      $jmap_tester->strip_json_types( $err ),
      {
        boat => superhashof({
          type => 'invalidProperties',
          propertyErrors => {
            is_delicious => 'not a valid boolean value',
          },
        }),
      },
      "Can't use a boolean-like value for a boolean property"
    );
  };

  subtest "make a recipe and a cake in one transaction" => sub {
    my $res = $jmap_tester->request([
      [
        setCakeRecipes => {
          create => {
            pav => { type => 'pavlova', avg_review => 50 }
          },
        },
      ],
      [
        setCakes => {
          create    => {
            magic => { type => 'eggy', layer_count => 2, recipeId => '#pav' },
          }
        },
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [ cakeRecipesSet => superhashof({
            created => {
              pav => {
                id => ignore(),
                is_delicious => bool(1),
                sku => re(qr/\A[0-9]{5}\z/),
              },
            }
        }) ],
        [ cakesSet       => superhashof({}) ],
      ],
      "we can bake cakes with recipes in one go",
    ) or note(explain($res->as_pairs));
  };

  subtest "subroutine defaults for lazy computation" => sub {
    my $next_sku_initial = $Bakesale::Schema::Result::CakeRecipe::NEXT_SKU;

    {
      my $res = $jmap_tester->request([
        [
          setCakeRecipes => {
            create => { pac => { type => 'pat-a-cake', avg_review => 81 } },
          },
        ],
      ]);

      my $sku = $res->single_sentence('cakeRecipesSet')
                    ->as_set
                    ->created->{pac}{sku};

      is("$sku", $next_sku_initial, "by default, next sku is from counter");
      is(
        $Bakesale::Schema::Result::CakeRecipe::NEXT_SKU,
        $next_sku_initial+1,
        "...and we update the next number"
      );
    }

    {
      my $res = $jmap_tester->request([
        [
          setCakeRecipes => {
            create => {
              bug => { type => 'insect', avg_review => 8, sku => 'BUG001' }
            },
          },
        ],
      ]);

      my $bug = $res->single_sentence('cakeRecipesSet')->as_set->created->{bug};
      ok( ! exists $bug->{sku}, "non-default sku, so not returned in set");

      is(
        $Bakesale::Schema::Result::CakeRecipe::NEXT_SKU,
        $next_sku_initial+1,
        "...and in that case, we do not update the next number"
      );

      my $bug_get_res = $jmap_tester->request([
        [ getCakeRecipes => { ids => [ $bug->{id} ] } ]
      ]);

      my $bug_get = $bug_get_res->single_sentence('cakeRecipes')
                                ->arguments
                                ->{list}[0];

      is("$bug_get->{sku}", "BUG001", "and the sku was set to what we wanted");
    }
  };

  {
    my $res = $jmap_tester->request([
      [
        setCookies => {
          ifInState => 9,
          destroy   => [ 3 ],
          create    => { blue => {} },
          update    => { 2 => { delicious => 0 } },
        },
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookiesSet => superhashof({
            oldState => 9,
            newState => 9,

            notCreated   => { blue => ignore() },
            notUpdated   => { 2    => ignore() },
            notDestroyed => { 3    => ignore() },
          }),
        ],
      ],
      "no state change when no destruction",
    );
  }

  {
    my $res = $jmap_tester->request([
      [
        setCookies => {
          create => { raw => { type => 'dough', baked_at => undef } },
        },
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookiesSet => superhashof({
            created => { raw => { id => re(qr/\S/), expires_at => ignore(), delicious => ignore(), external_id => ignore(), batch => ignore(), } },
          }),
        ],
      ],
      "we can create a record with a null date field",
    ) or diag(explain($jmap_tester->strip_json_types( $res->as_pairs )));
  }

  {
    my $res = $jmap_tester->request([
      [ setCookies => { create => { oatmeal => { type => 'oatmeal' } } } ],
      [ setCookies => { create => { mealoat => { type => 'oatmeal' } } } ],
    ]);

    my %state;
    my $s1; my sub s1 { $s1 = $_[0]; 1 };
    my $s2; my sub s2 { $s2 = $_[0]; 1 };

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookiesSet => superhashof({
            oldState => code(sub { $state{old} = $_[0]; 1 } ),
            newState => code(sub { $state{ s1} = $_[0]; 1 } ),
          }),
        ],
        [
          cookiesSet => superhashof({
            oldState => code(sub { $state{ s1} eq $_[0] }),
            newState => code(sub { $state{ s2} = $_[0]; 1 } ),
          }),
        ],
      ],
      "set twice in one request; first old state is second new state",
    );

    isnt($state{s2}, $state{s1}, "... second new state is distinct from first");
  }

  subtest "no-update update" => sub {
    my $res1 = $jmap_tester->request([
      [ setCookies => { create => { twisty => { type => 'oreo' } } } ],
    ]);

    my $set1 = $res1->single_sentence('cookiesSet')->as_set;
    my $id = $set1->created_id('twisty');

    my $res2 = $jmap_tester->request([
      [ setCookies => { update => { "$id" => { type => 'hydrox' } } } ],
    ]);

    my $set2 = $res2->single_sentence('cookiesSet')->as_set;

    is(  $set2->old_state, $set1->new_state, "1st update starts at create state");
    isnt($set2->new_state, $set1->new_state, "1st update ends at new state");

    my $res3 = $jmap_tester->request([
      [ setCookies => { update => { "$id" => { type => 'hydrox' } } } ],
    ]);

    my $set3 = $res3->single_sentence('cookiesSet')->as_set;

    is(  $set3->old_state, $set2->new_state, "2nd update starts at 1st update");
    is(  $set3->new_state, $set2->new_state, "2nd update does not change state");
  };

  subtest "delete the deleted" => sub {
    my $res1 = $jmap_tester->request([
      [ setCookies => { create => { doomed => { type => 'pistachio' } } } ],
    ]);

    my $set1 = $res1->single_sentence('cookiesSet')->as_set;
    my $id = $set1->created_id('doomed');

    my $res2 = $jmap_tester->request([
      [ setCookies => { destroy => [ "$id" ] } ],
    ]);

    my $set2 = $res2->single_sentence('cookiesSet')->as_set;

    is_deeply([ $set2->destroyed_ids ], [ $id ], "we destroy the item");

    my $res3 = $jmap_tester->request([
      [ setCookies => { destroy => [ "$id" ] } ],
    ]);

    my $set3 = $res3->single_sentence('cookiesSet')->as_set;

    is_deeply([ $set3->destroyed_ids ], [ ], "we destroy nothing");
    is_deeply([ $set3->not_destroyed_ids ], [ $id ], "...especially not $id");
  };

  subtest "duplicated creation ids" => sub {
    my $res = $jmap_tester->request([
      [
        setCakeRecipes => { create => {
          yummy => { type => 'yummykake', avg_review => 80 },
          tasty => { type => 'tastykake', avg_review => 80 },
        } }
      ],
      [
        setCakes => { create    => {
          yc1   => { type => 'y1', layer_count => 1, recipeId => '#yummy' },
          tc    => { type => 't1', layer_count => 2, recipeId => '#tasty' },
        } },
      ],
      [
        setCakeRecipes => { create => {
          yummy => { type => 'raspberry', avg_review => 82 },
          gross => { type => 'slugflour', avg_review => 12 },
        } }
      ],
      [
        setCakes => { create    => {
          yc2  => { type => 'y2', layer_count => 3, recipeId => '#yummy' },
          gc   => { type => 'g1', layer_count => 4, recipeId => '#gross' },
        } },
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cakeRecipesSet => superhashof({
            notCreated => {},
            created => {
              yummy => superhashof({}),
              tasty => superhashof({}),
            },
          })
        ],
        [
          cakesSet       => superhashof({
            notCreated => {},
            created => { yc1 => superhashof({}), tc => superhashof({}) },
          })
        ],
        [
          cakeRecipesSet => superhashof({
            created => { gross => superhashof({}), yummy => superhashof({}) },
          }),
        ],
        [
          cakesSet       => superhashof({
            notCreated => { yc2 => superhashof({ type => 'duplicateCreationId' }) },
            created => { gc => superhashof({}) },
          }),
        ],
      ],
    );
  };

  subtest "timestamptz field validations" => sub {
    my $tsrez = code(sub {
      defined $_[0]
           && $_[0] =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
    });

    my $res = $jmap_tester->request([
      [
        setCookies => {
          create    => {
            yellow => { type => 'yellow' }, # default baked_at
            gold   => { type => 'gold', baked_at => undef }, # null baked_at
            blue   => { type => 'blue', baked_at => '2016-01-01T12:34:56Z' },
            white  => { type => 'white', baked_at => '2016-01-01T12:34:57Z' },
            red    => { type => 'red', baked_at => '2016-01-01T12:34:56' },
            green  => { type => 'green', expires_at => undef },
            pink   => { type => 'pink', expires_at => '2016-01-01T12:34:56Z' },
            onyx   => { type => 'onyx', expires_at => '2016-01-01T12:34:57Z' },
            orange => { type => 'orange', baked_at => '2130-01-01T12:34:56Z' },
          },
        },
      ],
    ]);

    my $state;

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookiesSet => superhashof({
            oldState => ignore(),
            newState => code(sub { $state = $_[0]; 1}),
            created => {
              yellow => { id => ignore(), expires_at => ignore(), baked_at => $tsrez, delicious => ignore(), external_id => ignore, batch => ignore, },
              gold   => { id => ignore(), expires_at => ignore(), delicious => ignore(), external_id => ignore, batch => ignore, },
              blue   => { id => ignore(), expires_at => ignore(), delicious => ignore(), external_id => ignore, batch => ignore, },
              white  => { id => ignore(), expires_at => ignore(), delicious => ignore(), external_id => ignore, batch => ignore, },
              pink   => { id => ignore(), baked_at => ignore(), delicious => ignore(), external_id => ignore, batch => ignore, },
              onyx   => { id => ignore(), baked_at => ignore(), delicious => ignore(), external_id => ignore, batch => ignore, },
            },
            notCreated => {
              red => superhashof({
                type => 'invalidProperties',
                propertyErrors => { baked_at => 'invalid date value' },
              }),
              green => superhashof({
                type => 'invalidProperties',
                propertyErrors => { expires_at => 'null value given for field requiring a timestamptz' },
              }),
              orange => superhashof({
                'type' => 'timeSpaceContinuumFoul',
                'description' => 'You can\'t claim to have baked a cookie in the future',
              }),
            },
          }),
        ],
      ],
      "Check creating/updating with bad values or null values",
    ) or diag explain( $jmap_tester->strip_json_types( $res->as_pairs ) );

    # Verify
    $res = $jmap_tester->request([
      [
        getCookieUpdates => {
          sinceState => $state - 1,
          fetchRecords => \1,
          fetchRecordProperties => [ qw(type baked_at expires_at) ],
        },
      ],
    ]);

    my $data = $jmap_tester->strip_json_types($res->as_pairs);

    cmp_deeply(
      $data,
      [
        [ cookieUpdates => ignore() ],
        [
          cookies => {
            notFound => undef,
            state => $state,
            list  => bag(
              { id => ignore(), type => 'yellow', baked_at => $tsrez, expires_at => $tsrez, },
              { id => ignore(), type => 'gold', baked_at => undef, expires_at => $tsrez, },
              { id => ignore(), type => 'blue', baked_at => '2016-01-01T12:34:56Z', expires_at => $tsrez, },
              { id => ignore(), type => 'white', baked_at => '2016-01-01T12:34:57Z', expires_at => $tsrez, },
              { id => ignore(), type => 'pink', baked_at => $tsrez, expires_at => '2016-01-01T12:34:56Z' },
              { id => ignore(), type => 'onyx', baked_at => $tsrez, expires_at => '2016-01-01T12:34:57Z' },
            ),
          },
        ],
      ],
      "Defaults and explicit dates look right",
    ) or diag explain( $jmap_tester->strip_json_types( $res->as_pairs ) );

    my %c_to_id = map {;
      $_->{type} => $_->{id}
    } @{ $data->[1][1]{list} };

    $res = $jmap_tester->request([
      [
        setCookies => {
          update => {
            $c_to_id{yellow} => { type => 'tim tam' }, # Leave baked_at
            $c_to_id{gold}   => { baked_at => '2016-01-01T12:34:56Z' },
            $c_to_id{blue}   => { baked_at => undef }, # clear baked_at
            $c_to_id{white}  => { baked_at => '2016-01-01T12:34:56' },
            $c_to_id{pink}   => { expires_at => undef }, # bad
            $c_to_id{onyx}   => { type => 'black' }, # Leave expires_at
          },
        },
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookiesSet => superhashof({
            oldState => $state,
            newState => $state + 1,
            updated => {
              $c_to_id{yellow} => $no_updates,
              $c_to_id{gold} => $no_updates,
              $c_to_id{blue} => $no_updates,
              $c_to_id{onyx} => $no_updates,
            },
            notUpdated => {
              $c_to_id{white} => superhashof({
                type => 'invalidProperties',
                propertyErrors => { baked_at => 'invalid date value' },
              }),
              $c_to_id{pink} => superhashof({
                type => 'invalidProperties',
                propertyErrors => { expires_at => 'null value given for field requiring a timestamptz' },
              }),
            },
          }),
        ],
      ],
      "Check creating/updating with bad values or null values",
    ) or diag explain( $jmap_tester->strip_json_types( $res->as_pairs ) );

    $state++;

    # Verify (still using much older state so we can see white in the list)
    $res = $jmap_tester->request([
      [
        getCookieUpdates => {
          sinceState => $state - 2,
          fetchRecords => \1,
          fetchRecordProperties => [ qw(type baked_at expires_at) ],
        },
      ],
    ]);

    $data = $jmap_tester->strip_json_types($res->as_pairs);

    cmp_deeply(
      $data,
      [
        [ cookieUpdates => ignore() ],
        [
          cookies => {
            notFound => undef,
            state => $state,
            list  => set(
              { id => ignore(), type => 'tim tam', baked_at => $tsrez, expires_at => ignore() },
              { id => ignore(), type => 'gold', baked_at => '2016-01-01T12:34:56Z', expires_at => ignore() },
              { id => ignore(), type => 'blue', baked_at => undef, expires_at => ignore(), },
              { id => ignore(), type => 'white', baked_at => '2016-01-01T12:34:57Z', expires_at => ignore() },
              { id => ignore(), type => 'pink', baked_at => ignore(), expires_at => '2016-01-01T12:34:56Z', },
              { id => ignore(), type => 'black', baked_at => ignore(), expires_at => '2016-01-01T12:34:57Z' },
            ),
          },
        ],
      ],
      "Updates with exempt/explicit nulls look right",
    ) or diag explain( $jmap_tester->strip_json_types( $res->as_pairs ) );
  };

  subtest "db exceptions" => sub {
    # Make sure ix_create_error/update_error/destroy_error fire and work
    my $res = $jmap_tester->request([
      [ setUsers => {
        create => {
          first       => { username => 'first', },
          second      => { username => 'second', },
          nobody      => { username => 'nobody', status => 'active' },
        },
      } ],
    ]);

    my $created = $res->paragraph(0)->single('usersSet')->as_set;
    my $first_id = $created->created_id('first');
    my $second_id = $created->created_id('second');
    my $nobody_id = $created->created_id('nobody');

    ok($first_id, 'created user "first"');
    ok($second_id, 'created user "second"');
    ok($nobody_id, 'created user "nobody"');

    # Now try to create duplicate user first
    $res = $jmap_tester->request([
      [ setUsers => {
        create => {
          first       => { username => 'first', },
        },
      } ],
    ]);

    my $err = $res->paragraph(0)
                  ->single('usersSet')
                  ->as_set
                  ->create_errors;

    cmp_deeply(
      $jmap_tester->strip_json_types($err),
      {
        first => {
          'type' => 'alreadyExists',
          'description' => 'that username already exists during create',
        },
      },
      "duplicate usernames not possible",
    ) or diag explain $res->as_stripped_struct;

    # But we can 'create' duplicate 'nobody' users (it just returns the
    # the existing one
    $res = $jmap_tester->request([
      [ setUsers => {
        create => {
          first => { username => 'nobody', status => 'whatever' },
        },
      } ],
    ]);

    jcmp_deeply(
      $res->paragraph(0)->single('usersSet')->as_set->created,
      {
        first => {
          id       => $nobody_id,
          ranking  => ignore(),
        },
      },
      "Trying to create a nobody user just gives us back existing one",
    ) or diag explain $res->as_stripped_struct;

    # Try with update
    $res = $jmap_tester->request([
      [ setUsers => {
        update => {
          $first_id => { username => 'second', },
        },
      } ],
    ]);

    $err = $res->paragraph(0)
                  ->single('usersSet')
                  ->as_set
                  ->update_errors;

    cmp_deeply(
      $jmap_tester->strip_json_types($err),
      {
        $first_id => {
          'type' => 'alreadyExists',
          'description' => 'that username already exists during update',
        },
      },
      "duplicate usernames not possible",
    );

    # If we attempt to update a user to have the name 'nobody' Bakesale
    # will pretend that we succeed but there was really no updates. So
    # it should tell us our object was updated but the state should not
    # change

    # First, get state
    $res = $jmap_tester->request([
      [ getUsers => { ids => [ $first_id ] }, ],
    ]);

    ok(my $state = $res->single_sentence->arguments->{state}, "got state")
      or diag $res->as_stripped_struct;

    # Now attempt to change first user to 'nobody'
    $res = $jmap_tester->request([
      [ setUsers => {
        update => {
          $first_id => { username => 'nobody', },
        },
      } ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      superhashof({
        updated => { $first_id => $no_updates },
        oldState => $state,
        newState => $state,
      }),
      "Update can catch db errors and return as if an update happened",
    ) or diag explain $res->as_stripped_struct;
  };

  {
    # Make sure ix_set_check works
    my $res = $jmap_tester->request([
      [
        setCookies => {
          create => {
            actually_a_cake => { type => 'cake' },
          },
        }, 'first',
      ],
    ]);

    cmp_deeply(
      $res->as_stripped_struct->[0],
      [
        'error',
        {
          'description' => 'A cake is not a cookie',
          'type' => 'invalidArguments'
        },
        'first',
      ],
      "Got top level error from ix_set_check_arg",
    );
  }

  subtest "supplied created values changed" => sub {
    # If a user supplies a value to a field and we change it behind the
    # scenes during create, we need to supply the new value to the user
    # so that their data is in sync with ours
    my $res = $jmap_tester->request([
      [ setUsers => {
        create => {
          # status will remain active, we should not get status back
          active       => { username => 'active', status => 'active' },

          # status will be changed to active, we should get status back
          okay      => { username => 'okay', status => 'okay' },
        },
      } ],
    ]);

    my $created = $jmap_tester->strip_json_types(
      $res->paragraph(0)->single('usersSet')->as_set->created
    );

    cmp_deeply(
      $created,
      {
        active  => { id => ignore(), ranking => ignore(), },
        okay => { id => ignore(), ranking => ignore(), status => 'active' },
      },
      "Ix returns fields modified behind the scenes on create",
    ) or diag explain $created;
  };

  subtest "various string id tests" => sub {
    # id fields in JMAP are strings, but as far as Ix is concerned they
    # are integers only. Make sure junk string ids don't throw database
    # exceptions
    my $res = $jmap_tester->request([
      [ setCakes => {
        create => {
          "new" => { type => 'layered', layer_count => 4, recipeId => "cat", },
        },
        update => {
          "bad_id" => { type => 'layered' },
        },
        destroy => [ 'to_destroy' ],
      }, 'a', ],
      [
        getCakes => { ids => [ 'bad' ] }, 'b',
      ],
      [
        getCookieUpdates => { sinceState => 'bad' }, 'c',
      ],
    ]);

    cmp_deeply(
      $res->as_stripped_struct,
      [
        [
          'cakesSet',
          {
            'created' => {},
            'destroyed' => [],
            'newState' => ignore(),
            'notCreated' => {
              'new' => {
                'description' => 'invalid property values',
                'propertyErrors' => {
                  'recipeId' => 'invalid id string'
                },
                'type' => 'invalidProperties'
              }
            },
            'notDestroyed' => {
              'to_destroy' => {
                'description' => 'no such record found',
                'type' => 'notFound'
              }
            },
            'notUpdated' => {
              'bad_id' => {
                'description' => 'no such record found',
                'type' => 'notFound'
              }
            },
            'oldState' => ignore(),
            'updated' => {},
          },
          'a',
        ],
        [
          'cakes',
          {
            'list' => [],
            'notFound' => [
              'bad'
            ],
            'state' => ignore(),
          },
          'b',
        ],
        [
          'error',
          {
            'description' => 'invalid sinceState',
            'type' => 'invalidArguments',
          },
          'c'
        ]
      ],
      "malformed id fields throw proper errors"
    );
  };

  subtest "virtual properties in create" => sub {
    # If a class has virtual properties, they should come back in
    # the create call. For now this is up to subclasses to manage
    my $res = $jmap_tester->request([
      [ setUsers => {
        create => {
          virtualprops => { username => 'virtualprops', status => 'active' },
        },
      } ],
    ]);

    my $created = $jmap_tester->strip_json_types(
      $res->paragraph(0)->single('usersSet')->as_set->created
    );

    cmp_deeply(
      $created,
      {
        virtualprops  => { id => ignore(), ranking => 7  },
      },
      "Ix returns virtual fields on create",
    ) or diag explain $created;

    # Also comes back in gets
    $res = $jmap_tester->request([
      [ getUsers => { ids => [ $created->{virtualprops}->{id} ] } ],
    ]);

    my $got = $jmap_tester->strip_json_types(
      $res->paragraph(0)->single('users')->as_set->arguments->{list}->[0]
    );

    cmp_deeply(
      $got,
      superhashof({ ranking => 7 }),
      "got ranking back from getUsers"
    );
  };

  subtest "destroyed rows don't interfere with unique constraints" => sub {
    # Make sure destroyed rows don't interfere with unique constraints
    my $res = $jmap_tester->request([
      [ setUsers => {
        create => {
          first => { username => 'a new user', },
        },
      } ],
    ]);

    my $id = $res->paragraph(0)->single('usersSet')->as_set->created_id('first');
    ok($id, 'created a user');

    # Destroy that user
    $res = $jmap_tester->request([
       [ setUsers => {
         destroy => [ $id ],
       } ],
    ]);
    is(
      ($res->single_sentence('usersSet')->as_set->destroyed_ids)[0],
      $id,
      'user destroyed'
    );

    # Now create a new user with same username
    $res = $jmap_tester->request([
      [ setUsers => {
        create => {
          first => { username => 'a new user', },
        },
      } ],
    ]);

    my $id2 = $res->paragraph(0)->single('usersSet')->as_set->created_id('first');
    ok($id2, 'created a user with same username as destroyed user')
      or diag explain $res->as_stripped_struct;

    cmp_ok($id2, 'ne', $id, "new user has a different id");
  };

  subtest "non-ASCII data" => sub {
    subtest "HTTP, no database layer" => sub {
      for my $test (
        [ rjbs      => 4 ],
        [ 'Grüß'    => 4 ],
        [ '芋头糕'  => 3 ],
        # TODO: normalize, test for normalization
      ) {
        my $res = $jmap_tester->request([
          [ countChars => { string => $test->[0] } ],
        ]);

        my $got = $res->single_sentence('charCount')->as_stripped_pair->[1];

        my $data = JSON->new->utf8->decode($res->http_response->decoded_content);
        is($data->[0][1]->{string}, $test->[0], "string round tripped (HTTP)");

        is($got->{string}, $test->[0], "string round tripped (JMAP::Tester)");
        is($got->{length}, $test->[1], "correct length");
      }
    };

    subtest "row storage and retrieval" => sub {
      my $taro_cake = '芋头糕';
      my $shoefly   = "sh\N{LATIN SMALL LETTER O WITH DIAERESIS}"
                    . "o\N{COMBINING DIAERESIS}";

      isnt($shoefly, NFC($shoefly), "our shoefly name is not NFC");

      my $res = $jmap_tester->request([
        [
          setCakeRecipes => {
            create => {
              yum  => {
                type          => $shoefly,
                avg_review    => 99,
                is_delicious  => \1,
              },
              taro => {
                type          => $taro_cake,
                avg_review    => 62,
                is_delicious  => \1,
              }
            },
          },
        ],
      ]);

      my $set = $res->single_sentence->as_set;

      subtest "taro cake" => sub {
        my $id  = $set->created_id('taro');
        pass("created taro cake! id: $id");
        ok(! exists $set->created->{taro}{type}, "type used unaltered");
        my $cake = $jmap_tester->request([[ getCakeRecipes => { ids => [ $id ] } ]]);
        my $type = $cake->single_sentence('cakeRecipes')->arguments->{list}[0]{type};
        is($type, $taro_cake, "type round tripped");
      };

      subtest "shoefly pie" => sub {
        my $id  = $set->created_id('yum');
        pass("created shoefly cake (really it's pie)! id: $id");
        is($set->created->{yum}{type}, NFC($shoefly), "informed of str normalization");

        my $cake = $jmap_tester->request([[ getCakeRecipes => { ids => [ $id ] } ]]);
        my $type = $cake->single_sentence('cakeRecipes')->arguments->{list}[0]{type};
        isnt($type, $shoefly,       "type didn't round trip unaltered...");
        is($type,   NFC($shoefly),  "...because it got NFC'd");
      };
    };
  };

  subtest "ix_created test" => sub {
    # Creating a row can internally create another row and give us a result
    # (This tests ix_created hook) XXX - Test ix_updated/ix_destroyed hooks

    # Get topper state
    my $res = $jmap_tester->request([
      [
        getCakeToppers => { ids => [] }
      ],
    ]);
    ok(defined(my $state = $res->sentence(0)->arguments->{state}), 'got state');

    $res = $jmap_tester->request([
      [
        setCakes => {
          create => {
            yum => { type => 'wedding', layer_count => 4, recipeId => $account{recipes}{1} },
            woo => { type => 'wedding', layer_count => 8, recipeId => $account{recipes}{1} },
          }
        }, "my id"
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_stripped_struct ),
      [
        [
          cakesSet => superhashof({
            created => {
              yum => superhashof({ id => ignore() }),
              woo => superhashof({ id => ignore() }),
            },
          }), "my id"
        ],
        [
          cakeToppers => superhashof({
            list => set(
              {
                cakeId => $res->as_stripped_struct->[0][1]{created}{yum}{id},
                id => ignore(),
                type => 'wedding'
              },
              {
                cakeId => $res->as_stripped_struct->[0][1]{created}{woo}{id},
                id => ignore(),
                type => 'wedding'
              },
            ),
            notFound => ignore(),
            state => $state + 1,
          }), "my id"
        ],
      ],
      "we can bake wedding cakes and get back toppers",
    ) or diag explain( $jmap_tester->strip_json_types( $res->as_pairs ) );

    my $cstate = "" . $res->sentence(0)->arguments->{newState};
    my $tstate = "" . $res->sentence(1)->arguments->{state};

    ok($cstate, 'got cake state');
    ok($tstate, 'got cake topper state');

    is($tstate, $state + 1, 'state from update and tstate from get agree');

    # But can they throw sensible-ish errors?
    local @ENV{qw(NO_CAKE_TOPPERS QUIET_BAKESALE)} = (1, 1);

    print STDERR "Ignore the next two exception reports for now..\n";
    $res = $jmap_tester->request([
      [
        setCakes => {
          create => {
            yum => { type => 'wedding', layer_count => 4, recipeId => $account{recipes}{1} },
            woo => { type => 'wedding', layer_count => 8, recipeId => $account{recipes}{1} },
          }
        }, "my id"
      ],
    ]);

    cmp_deeply(
      $res->as_stripped_struct,
      [
        [
          cakesSet => superhashof({
            notCreated => {
              woo => { guid => ignore(), type => 'internalError' },
              yum => { guid => ignore(), type => 'internalError' },
            },
          }), 'my id'
        ]
      ],
      "errors bubble up"
    );

    is($res->http_response->header('Vary'), 'Origin', 'got Vary header');
    ok($res->http_response->header('Ix-Transaction-ID'), 'we have a request guid!');

    $res = $jmap_tester->request([ [ getCakes => { ids => [ 1 ] } ] ]);
    is("". $res->sentence(0)->arguments->{state}, $cstate, 'cake state unchanged');

    $res = $jmap_tester->request([ [ getCakeToppers => {} ] ]);
    is("". $res->sentence(0)->arguments->{state}, $tstate, 'cake topper state unchanged');
  };

  {
    $jmap_tester->_set_cookie('bakesaleUserId', $account{users}{alh});

    # Check state, should be 0
    my $res = $jmap_tester->request([
      [ getCookies => {} ],
    ]);

    is($res->single_sentence->arguments->{state}, 0, 'got state of 0')
      or diag $res->as_stripped_struct;

    # Ask for updates, should be told we are in sync
    $res = $jmap_tester->request([
      [ getCookieUpdates => {
          sinceState   => 0,
          fetchRecords => \1,
          fetchRecordProperties => [ qw(type) ],
        }
      ],
    ]);

    my $args = $res->single_sentence->arguments;
    is($args->{newState}, 0, "newState is right");
    is($args->{oldState}, 0, "oldState is right");
    is_deeply($args->{changed}, [], 'no changes');

    # Add some cookies, ensure ifInState works
    $res = $jmap_tester->request([
      [
        setCookies => {
          ifInState => 0,
          create    => {
            yellow => { type => 'shortbread', },
            gold   => { type => 'anzac' },
          },
        },
      ],
    ]);

    cmp_deeply(
      $jmap_tester->strip_json_types( $res->as_pairs ),
      [
        [
          cookiesSet => superhashof({
            oldState => 0,
            newState => 1,

            created => {
              yellow => superhashof({ id => ignore(), }),
              gold   => superhashof({ id => ignore() }),
            },
          }),
        ],
      ],
      "we can create cookies with ifInState 0",
    ) or diag(explain($jmap_tester->strip_json_types( $res->as_pairs )));

    my @created_ids = $res->single_sentence->as_set->created_ids;
    is(@created_ids, 2, 'got two created ids');

    # Verify updates
    $res = $jmap_tester->request([
      [ getCookieUpdates => { sinceState => '0' } ],
    ]);

    cmp_deeply(
      $res->as_stripped_struct->[0][1]{changed},
      set(map { "$_" } @created_ids),
      "getCookieUpdates with state of 0 works"
    );

    # If our sinceState is too low we should get a resync
    $res = $jmap_tester->request([
      [ getCookieUpdates => {
          sinceState   => -1,
          fetchRecords => \1,
          fetchRecordProperties => [ qw(type) ],
        }
      ],
    ]);

    jcmp_deeply(
      $res->as_stripped_struct->[0][1],
      {
        description => 'client cache must be reconstructed',
        type => 'cannotCalculateChanges'
      },
      "Got resync error with too low sinceState"
    ) or diag explain $res->as_stripped_struct;

    # Complex ones too
    $res = $jmap_tester->request([
      [ getCakeUpdates => { sinceState => '0-0' }, ],
    ]);

    $args = $res->single_sentence->arguments;
    is($args->{newState}, "0-0", "newState is right");
    is($args->{oldState}, "0-0", "oldState is right");
    is_deeply($args->{changed}, [], 'no changes');

    # Put this back
    $jmap_tester->_set_cookie('bakesaleUserId', $account{users}{rjbs});
  }

  subtest "deleted entites in get*Updates calls" => sub {
    # Create a cookie at state A.
    # Update it at state B.
    # Destroy it at state C.
    #
    # If we ask for updates between A-1 and C, we should not see the cookie
    # since it was created/destroyed entirely inside our window.
    #
    # If we ask for updates between A-C, we should only see that the cookie
    # is destroyed, since it was updated and then destroyed entirely inside
    # our window, and the update is inconsequential

    # Get current state
    my $res = $jmap_tester->request([
      [ getCookies => {} ],
    ]);
    my $start = $res->single_sentence->arguments->{state};
    ok($start, 'got starting cookie state');

    # Create a cookie
    $res = $jmap_tester->request([
      [ setCookies => { create => { doomed => { type => 'pistachio' } } } ],
    ]);

    my $id = $res->single_sentence('cookiesSet')->as_set->created_id('doomed');
    ok($id, 'created a doomed cookie');

    my $create = $res->single_sentence->arguments->{newState};
    ok($create, 'got created cookie state');

    # Update it
    $res = $jmap_tester->request([
      [ setCookies => { update => { $id => { type => 'almond' } } } ],
    ]);

    is_deeply(
      [ $res->single_sentence('cookiesSet')->as_set->updated_ids ],
      [ $id ],
      "cookie was updated"
    );

    my $update = $res->single_sentence->arguments->{newState};
    ok($update, 'got updated cookie state');

    # Destroy it with lazers
    $res = $jmap_tester->request([
      [ setCookies => { destroy => [ "$id" ] } ],
    ]);

    is_deeply(
      [ $res->single_sentence('cookiesSet')->as_set->destroyed_ids ],
      [ $id ],
      "cookie was destroyed"
    );

    my $destroy = $res->single_sentence->arguments->{newState};
    ok($destroy, 'got destroyed cookie state');

    for my $test (
      [ $start,  { changed => [     ], removed => [     ] },
        "create/update/destroy in update window not seen",
      ],
      [ $create, { changed => [     ], removed => [ $id ] },
        "update/destroy in window shows destroy but no update",
      ],
      [ $update, { changed => [     ], removed => [ $id ] },
        "destroy in window shows destroy but no update",
      ],
    ) {
      my ($state, $expect, $desc) = @$test;

      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => $state } ],
      ]);

      jcmp_deeply(
        $res->single_sentence->arguments,
        superhashof($expect),
        $desc
      ) or diag explain $res->as_stripped_struct;
    }
  };

  subtest "additional request handling" => sub {
    $app->clear_transaction_log;

    my $uri = $jmap_tester->api_uri;
    $uri =~ s/jmap$/secret/;
    my $res = $jmap_tester->ua->get($uri);
    is(
      $res->content,
      "Your secret is safe with me.\n",
      "we can hijack request handling",
    );

    my @xacts = $app->drain_transaction_log;
    is(@xacts, 1, "we log the /secret transaction");

    is(
      join(q{}, $xacts[0]{response}[2]->@*),
      "Your secret is safe with me.\n",
      "...and it has the response body, for example",
    );
  };

  subtest "good call gets headers" => sub {
    $jmap_tester->ua->default_header('Origin' => 'example.net');

    my $res = $jmap_tester->request([
      [ getCookies => {} ],
    ]);

    ok($res->sentence(0)->arguments->{list}, 'got a good response');

    my $http_res = $res->http_response;

    for my $hdr (
      [ 'Vary', 'Origin' ],
      [ 'Access-Control-Allow-Origin', 'example.net' ],
      [ 'Access-Control-Allow-Credentials', 'true' ],
    ) {
      is(
        $http_res->header($hdr->[0]),
        $hdr->[1],
        "$hdr->[0] is correct"
      );
    }

    ok($http_res->header('Ix-Transaction-ID'), 'we have a request guid!');
  };

  subtest "dateDestroyed has timezone" => sub {
    my $res1 = $jmap_tester->request([
      [ setCookies => { create => { doomed => { type => 'pistachio' } } } ],
    ]);

    my $set1 = $res1->single_sentence('cookiesSet')->as_set;
    my $id = $set1->created_id('doomed');

    my $res2 = $jmap_tester->request([
      [ setCookies => { destroy => [ "$id" ] } ],
    ]);

    my $set2 = $res2->single_sentence('cookiesSet')->as_set;

    is_deeply([ $set2->destroyed_ids ], [ $id ], "we destroy the item");

    # Verify
    $app->processor->schema_connection->storage->dbh_do(
      sub {
        my ($storage, $dbh) = @_;

        my $raw = $dbh->selectall_arrayref(
          'SELECT "dateDestroyed" FROM cookies WHERE id = ?', {}, $id,
        );

        like(
          $raw->[0][0],
          qr/\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\+00/a,
          'dateDestroyed contains a timezone (UTC by default)'
        );
      }
    );
  };

  subtest "optional idstr" => sub {
    # Create a cookie with an external_id
    my $res = $jmap_tester->request([
      [
        setCookies => {
          create => { raw => { type => 'dough', baked_at => undef, external_id => ix_new_id() } },
        },
      ],
    ]);

    jcmp_deeply(
      $res->sentence(0)->arguments->{created},
      {
        raw => { id => re(qr/\S/), expires_at => ignore(), delicious => ignore(), batch => ignore, }
      },
      "created a cookie with an external_id",
    ) or diag(explain($jmap_tester->strip_json_types( $res->as_pairs )));

    my $id = $res->sentence(0)->as_set->created_id('raw');

    $res = $jmap_tester->request([
      [
        setCookies => {
          update => {
            $id => { external_id => undef },
          },
        },
      ],
    ]);

    jcmp_deeply(
      $res->sentence(0)->arguments->{updated},
      { $id => undef },
      "unset external_id"
    ) or diag explain $res->as_stripped_struct;
  };

  subtest "ix_custom_deployment_statements" => sub {
    my $res = $jmap_tester->request([
      [ setUsers => {
        create => {
          first       => { username => 'case', },
          second      => { username => 'CASE', },
        },
      } ],
    ]);

    my $arg = $res->single_sentence->arguments;

    is(keys $arg->{created}->%*, 1, 'created one user');
    is(keys $arg->{notCreated}->%*, 1, 'failed to create one user');
    jcmp_deeply(
      (values $arg->{notCreated}->%*)[0],
      superhashof({
        description => re(qr/already exists/),
      }),
      'our custom sql works'
    );
  };

  subtest "friendly duplicate key errors" => sub {
    my $create_res = $jmap_tester->request([
      [ setUsers => {
        create => {
          first  => { username => 'kaboom', },
          second => { username => 'anewuser2' },
          kaboom => { username => 'kaboom'  },
        },
      } ],
    ]);

    my $set = $create_res->single_sentence->as_set;

    ok(my $second = $set->created_id('second'), 'created second user');

    my $err = $create_res->single_sentence->arguments->{notCreated};
    is(keys %$err, 1, 'one row failed to create');

    jcmp_deeply(
      (values %$err)[0],
      {
        type => 'invalidRecord',
        description => 'create conflicts with existing object',
      },
      'got frieindly duplicate key error'
    );

    # Same with update
    my $update_res = $jmap_tester->request([
      [ setUsers => {
        update => {
          $second => { username => 'kaboom' },
        },
      } ],
    ]);

    jcmp_deeply(
      $update_res->single_sentence->arguments->{notUpdated},
      {
        $second => {
          type => 'invalidRecord',
          description => 'update conflicts with existing object',
        },
      },
      'got frieindly duplicate key error'
    );
  };

  subtest "cannot update a destroyed row" => sub {
    my $create_res = $jmap_tester->request([
      [ setUsers => {
        create => {
          first  => { username => 'auser', },
        },
      } ],
    ]);

    ok(
      my $first_id = $create_res->single_sentence->as_set->created_id('first'),
      'created first user'
    );

    # Destroy it
    my $destroy_res = $jmap_tester->request([
      [ setUsers => {
        destroy => [ $first_id ],
      } ],
    ]);

    is(
      $destroy_res->single_sentence->as_set->destroyed_ids,
      1,
      'destroyed first user'
    );

    my $update_res = $jmap_tester->request([
      [ setUsers => {
        update => {
          $first_id => { username => 'buser' },
        },
      } ]
    ]);

    jcmp_deeply(
      $update_res->single_sentence->arguments->{notUpdated},
      {
        $first_id => {
          'description' => 'no such record found',
          'type' => 'notFound'
        },
      },
      "cannot update a destroyed record"
    );
  };

  subtest "ix_custom_deployment_statements" => sub {
    my $set_res = $jmap_tester->request([
      [ setUsers => {
        create => {
          first => { username => 'someuser', },
        },
      } ],
    ]);

    my $set = $set_res->single_sentence->as_set;
    ok(my $id = $set->as_set->created_id('first'), 'created one user');

    my $get_res = $jmap_tester->request([
      [ getUserList => {
        filter => { username => 'SOMEUSER' },
      } ],
    ]);

    jcmp_deeply(
      $get_res->single_sentence->arguments->{userIds},
      [ $id ],
      'Able to grab our user using case-insensitive search'
    );
  };

  subtest "space cookies (are totally canceled)" => sub {
    my $res = $jmap_tester->request([[
      setCookies => {
        outofthisworld => 1,

        create => { raw => { type => 'stardust', baked_at => undef } },
      },
    ]]);
    jcmp_deeply(
      $res->single_sentence->arguments->{type},
      'invalidPermissions',
      'you are not authorized to make this call'
    );
  };

}

done_testing;
