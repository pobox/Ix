use 5.20.0;
use warnings;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use Test::Deep;
use Test::More;
use JSON;

my ($app, $jmap_tester) = Bakesale::Test->new_test_app_and_tester;
\my %dataset = Bakesale::Test->load_trivial_dataset($app->processor->schema_connection);

$jmap_tester->_set_cookie('bakesaleUserId', $dataset{users}{rjbs});

{
  my $res = $jmap_tester->request([
    [ pieTypes => { tasty => 1 } ],
    [ pieTypes => { tasty => 0 } ],
  ]);

  cmp_deeply(
    $jmap_tester->strip_json_types( $res->sentence(0)->as_pair ),
    [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] } ],
    "first call response: as expected",
  );

  cmp_deeply(
    $jmap_tester->strip_json_types( $res->paragraph(1)->single->as_pair ),
    [ pieTypes => { flavors => [ qw(pumpkin apple pecan cherry eel) ] } ],
    "second call response group: one item, as expected",
  );
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

  cmp_deeply(
    $jmap_tester->strip_json_types( $bake->as_pairs ),
    [
      [ pie   => { flavor => 'apple', bakeOrder => 1 } ],
      [ error => { type => 'noRecipe', requestedPie => 'eel' } ],
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
    [ getCookies => { sinceState => 2, properties => [ qw(type) ] } ],
  ]);

  isa_ok(
    $res->as_struct->[0][1]{list}[0]{id},
    'JSON::Typist::String',
    "the returned id",
  ) or diag(explain($res->as_struct));

  cmp_deeply(
    $jmap_tester->strip_json_types( $res->as_pairs ),
    [
      [
        cookies => {
          notFound => undef,
          state => 8,
          list  => [
            { id => $dataset{cookies}{4}, type => 'samoa',   }, # baked_at => 1455319240 },
            { id => $dataset{cookies}{5}, type => 'tim tam', }, # baked_at => 1455310000 },
            { id => $dataset{cookies}{6}, type => 'immortal', }, # baked_at => 1455310000 },
          ],
        },
      ],
    ],
    "a getFoos call backed by the database",
  );
}

{
  my @ids = values $dataset{cookies}->%*;
  my $does_not_exist = $ids[-1]+1;

  my $res = $jmap_tester->request([
    [
      getCookies => {
        ids        => [ $dataset{cookies}{4}, $does_not_exist ],
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
            { id => $dataset{cookies}{4}, type => "samoa" }, # baked_at => 1455319240 },
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
        },
        update => {
          $dataset{cookies}{1} => { type => 'half-eaten tim-tam' },
          $dataset{cookies}{2} => { pretty_delicious => 0, id => 999 },
        },
        destroy => [ $dataset{cookies}->@{3, 4, 6} ],
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
            yellow => { id => ignore(), expires_at => ignore(), delicious => ignore() }, # no baked_at, because not default
            gold   => { id => ignore(), expires_at => ignore, baked_at => ignore(), delicious => ignore() },
          },
          notCreated => {
            blue   => superhashof({
              type => 'invalidProperties',
              propertyErrors => { type => 'no value given for required field' }
            }),
          },
          updated => [ $dataset{cookies}{1} ],
          notUpdated => {
            $dataset{cookies}{2} => superhashof({
              type => 'invalidProperties',
              propertyErrors => {
                pretty_delicious => "unknown property",
                id => re(qr/cannot be set/),
              },
            }),
          },
          destroyed => [ $dataset{cookies}{4} ],
          notDestroyed => {
            $dataset{cookies}{3} => superhashof({ type => ignore() }),
            $dataset{cookies}{6} => superhashof({ description => 'You can\'t destroy an immortal cookie!'}),
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
          $dataset{cookies}{1} => { type => 'tim-tam' },
          $dataset{cookies}{2} => { baked_at => '2301-01-01T12:12:12Z' },
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
            $dataset{cookies}{1} => superhashof({
              'type' => 'partyFoul',
              'description' => 'You can\'t pretend you haven\'t eaten a part of that coookie!',
            }),
            $dataset{cookies}{2} => superhashof({
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
          changed  => bag($dataset{cookies}{1}, @created_ids),
          removed  => bag($dataset{cookies}{4}),
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
      [ getCookieUpdates => { sinceState => 1 } ],
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
    [ getCookies => { ids => [ $dataset{cookies}{1}, @created_ids ] } ],
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
          changed  => bag($dataset{cookies}{1}, @created_ids),
          removed  => bag($dataset{cookies}{4}),
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
          yum => { type => 'wedding', layer_count => 4, recipeId => $dataset{recipes}{1} },
          yow => { type => 'croquembouche', layer_count => 99, recipeId => $dataset{recipes}{1} }
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
            boat => { id => ignore() },
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
            pav => { id => ignore(), is_delicious => bool(1) },
          }
      }) ],
      [ cakesSet       => superhashof({}) ],
    ],
    "we can bake cakes with recipes in one go",
  ) or note(explain($res->as_pairs));
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
          created => { raw => { id => re(qr/\S/), expires_at => ignore(), delicious => ignore() } },
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

subtest "datetime field validations" => sub {
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
            yellow => { id => ignore(), expires_at => ignore(), baked_at => $tsrez, delicious => ignore(), },
            gold   => { id => ignore(), expires_at => ignore(), delicious => ignore(), },
            blue   => { id => ignore(), expires_at => ignore(), delicious => ignore(), },
            white  => { id => ignore(), expires_at => ignore(), delicious => ignore(), },
            pink   => { id => ignore(), baked_at => ignore(), delicious => ignore(), },
            onyx   => { id => ignore(), baked_at => ignore(), delicious => ignore(), },
          },
          notCreated => {
            red => superhashof({
              type => 'invalidProperties',
              propertyErrors => { baked_at => 'invalid date value' },
            }),
            green => superhashof({
              type => 'invalidProperties',
              propertyErrors => { expires_at => 'null value given for field requiring a datetime' },
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
    [ getCookies => { sinceState => $state - 1, properties => [ qw(type baked_at expires_at) ] } ],
  ]);

  my $data = $jmap_tester->strip_json_types($res->as_pairs);

  cmp_deeply(
    $data,
    [
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
  } @{ $data->[0][1]{list} };

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
          updated => set(
            $c_to_id{yellow},
            $c_to_id{gold},
            $c_to_id{blue},
            $c_to_id{onyx},
          ),
          notUpdated => {
            $c_to_id{white} => superhashof({
              type => 'invalidProperties',
              propertyErrors => { baked_at => 'invalid date value' },
            }),
            $c_to_id{pink} => superhashof({
              type => 'invalidProperties',
              propertyErrors => { expires_at => 'null value given for field requiring a datetime' },
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
    [ getCookies => { sinceState => $state - 2, properties => [ qw(type baked_at expires_at) ] } ],
  ]);

  $data = $jmap_tester->strip_json_types($res->as_pairs);

  cmp_deeply(
    $data,
    [
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
      },
    } ],
  ]);

  my $created = $res->paragraph(0)->single('usersSet')->as_set;
  my $first_id = $created->created_id('first');
  my $second_id = $created->created_id('second');

  ok($first_id, 'created user "first"');
  ok($second_id, 'created user "second"');

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
  );

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
        'descriptoin' => 'A cake is not a cookie',
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
      active  => { id => ignore(), },
      okay => { id => ignore(), status => 'active' },
    },
    "Ix returns fields modified behind the scenes on create",
  ) or diag explain $created;
};

done_testing;
