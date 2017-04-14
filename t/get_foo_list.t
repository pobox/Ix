use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use JSON::MaybeXS ();
use Test::Deep;
use Test::Deep::JType;
use Test::More;
use Test::Abortable 'subtest';
use Unicode::Normalize;

{
  my ($test_env) = Bakesale::Test->new_test_env;
  my ($app, $jmap_tester) = $test_env->@{qw(app tester)};

  \my %account = Bakesale::Test->load_trivial_account(
    $app->processor->schema_connection
  );

  $jmap_tester->_set_cookie('bakesaleUserId', $account{users}{rjbs});

  # Create some recipes
  my $res = $jmap_tester->request([
    [
      setCakeRecipes => {
        create => {
          secret1 => {
            type          => 'secret1',
            avg_review    => 0,
            is_delicious  => jtrue,
          },
          secret2 => {
            type          => 'secret2',
            avg_review    => 0,
            is_delicious  => jfalse,
          },
        },
      },
    ],
  ]);

  my $secret1_recipe_id = $res->single_sentence->as_set->created_id('secret1');
  my $secret2_recipe_id = $res->single_sentence->as_set->created_id('secret2');

  ok($secret1_recipe_id, 'created a chocolate recipe');
  ok($secret2_recipe_id, 'created a marble recipe');

  {
    # Try to getCakeList / getCakeListUpdates - should work but return nothing
    my $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'created asc' ],
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      superhashof({
        cakeIds => [],
        state   => 0,
        total   => 0,
      }),
      "ix_get_list works with no state rows"
    );

    $res = $jmap_tester->request([
      [
        getCakeListUpdates => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'created asc' ],
          sinceState => 0,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      superhashof({
        added    => [],
        removed  => [],
        total    => 0,
        newState => 0,
        oldState => 0,
      }),
      "ix_get_list_update works with no state rows"
    );
  }

  # Now create a few cakes under each one
  $res = $jmap_tester->request([
    [
      setCakes => {
        create => {
          'chocolate1' => {
            type => 'chocolate', layer_count => 1, recipeId => $secret1_recipe_id,
          },
          'chocolate2' => {
            type => 'chocolate', layer_count => 3, recipeId => $secret1_recipe_id,
          },
          'pb1' => {
            type => 'peanut butter', layer_count => 3, recipeId => $secret1_recipe_id,
          },
          'marble1' => {
            type => 'marble', layer_count => 1, recipeId => $secret2_recipe_id,
          },
          'marble2' => {
            type => 'marble', layer_count => 3, recipeId => $secret2_recipe_id,
          },
          'lemon1' => {
            type => 'lemon', layer_count => 3, recipeId => $secret2_recipe_id,
          },
        },
      },
    ]
  ]);

  my %cake_id;
  for my $k (qw(chocolate1 chocolate2 pb1 marble1 marble2 lemon1)) {
    ok($cake_id{$k} = $res->sentence(0)->as_set->created_id($k), "created cake $k");
  }

  my $state = $res->sentence(0)->arguments->{newState};
  ok(defined($state), 'got state') or diag explain $res->as_stripped_struct;
  $state =~ s/-\d+//;

  {
    # Basic Filter/sort tests
    # Two chocolate cakes should come first in order of ids, peanut butter
    # after
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'type asc' ],
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'cakeIds' => [
          ( sort { $a cmp $b } @cake_id{qw(chocolate1 chocolate2)} ),
          $cake_id{pb1},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id
        },
        'canCalculateUpdates' => jtrue,
        'position' => 0,
        'sort' => [
          'type asc',
        ],
        'state' => $state,
        'total' => 3,
      },
      "getCakeList with sort+filter looks right"
    ) or diag explain $res->as_stripped_struct;

    # Same but reverse sort
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'type desc' ],
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'cakeIds' => [
          $cake_id{pb1},
          # These will still be in .id asc order since we always sort on id
          # last to ensure consistency between results when all other sorts
          # leave adjacent rows that could be ordered differently
          ( sort { $a cmp $b } @cake_id{qw(chocolate1 chocolate2)} ),
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id
        },
        'canCalculateUpdates' => jtrue,
        'position' => 0,
        'sort' => [
          'type desc'
        ],
        'state' => $state,
        'total' => 3,
      },
      "getCakeList with sort+filter looks right (reverse sort)"
    );
  }

  subtest "custom condition builder" => sub {
    # We have two recipes.  For each recipe, we have three cakes, and one of them
    # is single-layer.
    for my $recipe_id ($secret1_recipe_id, $secret2_recipe_id) {
      my $total_res = $jmap_tester->request([
        [ getCakeList => { filter => { recipeId => $recipe_id } } ],
      ]);

      jcmp_deeply(
        $total_res->single_sentence('cakeList')->arguments,
        superhashof({ total => jnum(3) }),
        "there! are! THREE! cakes!",
      );

      my $short_res = $jmap_tester->request([
        [ getCakeList => { filter => {
            recipeId => $recipe_id, isLayered => jfalse
          } }
        ],
      ]);

      jcmp_deeply(
        $short_res->single_sentence('cakeList')->arguments,
        superhashof({ total => jnum(1) }),
        "...one cake is single-layered",
      );

      my $tall_res = $jmap_tester->request([
        [ getCakeList => { filter => {
            recipeId => $recipe_id, isLayered => jtrue
          } }
        ],
      ]);

      jcmp_deeply(
        $tall_res->single_sentence('cakeList')->arguments,
        superhashof({ total => jnum(2) }),
        "...two cakes are multi-layered",
      );
    }
  };

  {
    # Ensure multiple sort orders work. First, sort by layer_count asc
    # then layer_count desc
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'type asc', 'layer_count asc' ],
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'cakeIds' => [
          @cake_id{qw(chocolate1 chocolate2 pb1)},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id
        },
        'canCalculateUpdates' => jtrue,
        'position' => 0,
        'sort' => [
          'type asc',
          'layer_count asc',
        ],
        'state' => $state,
        'total' => 3,
      },
      "getCakeList with multi-sort + filter looks right"
    );

    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'type asc', 'layer_count desc' ],
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'cakeIds' => [
          @cake_id{qw(chocolate2 chocolate1 pb1)},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id
        },
        'canCalculateUpdates' => jtrue,
        'position' => 0,
        'sort' => [
          'type asc',
          'layer_count desc',
        ],
        'state' => $state,
        'total' => 3,
      },
      "getCakeList with multi-sort + filter looks right"
    );
  }

  {
    # 2nd filter, no sort specified
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId => $secret1_recipe_id,
            type     => 'peanut butter',
          },
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'cakeIds' => [
          @cake_id{qw(pb1)},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
          'type'     => 'peanut butter',
        },
        'canCalculateUpdates' => jtrue,
        'position' => 0,
        'sort' => undef,
        'state' => $state,
        'total' => 1,
      },
      "getCakeList with no sort, multi-filter"
    );
  }

  {
    # Pagination
    my $p = 0;

    for my $cid (sort { $a cmp $b } @cake_id{qw(chocolate1 chocolate2 pb1)}) {
      $res = $jmap_tester->request([
        [
          getCakeList => {
            filter => {
              recipeId => $secret1_recipe_id,
            },
            sort => [],
            position => $p++,
            limit    => 1,
          },
        ],
      ]);

      jcmp_deeply(
        $res->single_sentence->arguments,
        {
          'cakeIds' => [
            $cid,
          ],
          'filter' => {
            'recipeId' => $secret1_recipe_id
          },
          'canCalculateUpdates' => jtrue,
          'position' => $p-1,
          'sort' => [],
          'state' => $state,
          'total' => 3,
        },
        "getCakeList with limit 1, position $p looks right (got cake $cid)"
      );
    }
  }

  # XXX - Test for limit set at 500 if fetching extras
  #       -- alh, 2016-11-22

  {
    # fetch args
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId   => $secret1_recipe_id,
            type       => 'peanut butter',
          },
          fetchCakes => jtrue,
        },
      ],
    ]);

    jcmp_deeply(
      $res->sentence(0)->arguments,
      {
        'cakeIds' => [
          @cake_id{qw(pb1)},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
          'type'     => 'peanut butter',
        },
        'canCalculateUpdates' => jtrue,
        'position' => 0,
        'sort' => undef,
        'state' => $state,
        'total' => 1,
      },
      "getCakeList with fetchCakes => 1"
    ) or diag explain $res->as_stripped_struct;

    jcmp_deeply(
      $res->sentence(1)->arguments->{list},
      [
        superhashof({
          id => $cake_id{pb1},
          type => 'peanut butter',
        }),
      ],
      "got cake back with fetchCakes => 1"
    ) or diag explain $res->as_stripped_struct;

    # Fetching just the recipes should work
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId   => $secret1_recipe_id,
            type       => 'peanut butter',
          },
          fetchRecipes => jtrue,
        },
      ],
    ]);

    jcmp_deeply(
      $res->sentence(0)->arguments,
      {
        'cakeIds' => [
          @cake_id{qw(pb1)},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
          'type'     => 'peanut butter',
        },
        'canCalculateUpdates' => jtrue,
        'position' => 0,
        'sort' => undef,
        'state' => $state,
        'total' => 1,
      },
      "getCakeList with fetchRecipes => 1 but no fetchCakes"
    ) or diag explain $res->as_stripped_struct;

    jcmp_deeply(
      $res->sentence(1)->arguments->{list},
      [
        superhashof({
          id => $secret1_recipe_id,
          type => 'secret1',
        }),
      ],
      "got recipe back with no fetchCakes and fetchRecipes => 1"
    ) or diag explain $res->as_stripped_struct;

    # Provide both
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId   => $secret1_recipe_id,
            type       => 'peanut butter',
          },
          fetchCakes   => jtrue,
          fetchRecipes => jtrue,
        },
      ],
    ]);

    jcmp_deeply(
      $res->sentence(0)->arguments,
      {
        'cakeIds' => [
          @cake_id{qw(pb1)},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
          'type'     => 'peanut butter',
        },
        'canCalculateUpdates' => jtrue,
        'position' => 0,
        'sort' => undef,
        'state' => $state,
        'total' => 1,
      },
      "getCakeList with fetchCakes => 1"
    ) or diag explain $res->as_stripped_struct;

    jcmp_deeply(
      $res->sentence(1)->arguments->{list},
      [
        superhashof({
          id => $cake_id{pb1},
          type => 'peanut butter',
        }),
      ],
      "got cake back with fetchCakes => 1"
    ) or diag explain $res->as_stripped_struct;

    jcmp_deeply(
      $res->sentence(2)->arguments->{list},
      [
        superhashof({
          id => $secret1_recipe_id,
          type => 'secret1',
        }),
      ],
      "got recipe back with fetchCakes => 1 and fetchRecipes => 1"
    ) or diag explain $res->as_stripped_struct;
  }

  {
    # bad forms. Missing required filter, bad second filter, missing
    # sort direction, bad sort
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            fake => 'not a real field',
          },
          sort => [ 'type', 'fake asc', 'layer_count asc bad', 'layer_count bad' ],
          fetchCakes   => jtrue,
          fetchRecipes => jtrue,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'type' => 'invalidArguments',
        'description' => 'Invalid arguments',
        'invalidFilters' => {
          'fake'     => 'unknown filter field',
          'recipeId' => 'required filter missing',
        },
        'invalidSorts' => {
          'fake asc'    => 'unknown sort field',
          'type'        => 'invalid sort format: missing sort order',
          'layer_count bad' => "invalid sort format: sort order must be 'asc' or 'desc'",
          'layer_count asc bad' => "invalid sort format: expected exactly two arguments",
        },
      },
      "bad getList forms detected",
    ) or diag explain $res->as_stripped_struct;
  }

  {
    # Delete a cake, ensure it doesn't come back in list
    $res = $jmap_tester->request([
      [
        setCakes => {
          destroy => [ $cake_id{chocolate1} ],
        },
      ],
    ]);

    jcmp_deeply(
      [ $res->single_sentence->as_set->destroyed_ids() ],
      [ $cake_id{chocolate1}, ],
      'ate a cake'
    );

    $state++;

    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'type asc' ],
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'cakeIds' => [
          @cake_id{qw(chocolate2 pb1)},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id
        },
        'canCalculateUpdates' => jtrue,
        'position' => 0,
        'sort' => [
          'type asc',
        ],
        'state' => $state,
        'total' => 2,
      },
      "getCakeList doesn't show destroyed cakes"
    );
  }

  {
    # _updates. We should see two cake adds (not three, since one was
    # deleted at the end state so why bother showing the addition?
    $res = $jmap_tester->request([
      [
        getCakeListUpdates => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'type asc' ],
          sinceState => $state - 2,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'added' => [
          {
            'cakeId' => $cake_id{chocolate2},
            'index' => 0,
          },
          {
            'cakeId' => $cake_id{pb1},
            'index' => 1,
          }
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
        },
        'newState' => jstr($state),
        'oldState' => jstr($state-2),
        'removed' => [],
        'sort' => [
          'type asc'
        ],
        'total' => 2
      },
      "getCakeListUpdates looks right for added cakes"
    ) or diag explain $res->as_stripped_struct;

    # Now try from state-1, should show removal
    $res = $jmap_tester->request([
      [
        getCakeListUpdates => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'type asc' ],
          sinceState => $state - 1,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'added' => [],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
        },
        'newState' => jstr($state),
        'oldState' => jstr($state-1),
        'removed' => [
          $cake_id{chocolate1},
        ],
        'sort' => [
          'type asc'
        ],
        'total' => 2
      },
      "getCakeListUpdates looks right for removed cake"
    ) or diag explain $res->as_stripped_struct;
  }

  {
    # No sinceState
    $res = $jmap_tester->request([
      [
        getCakeListUpdates => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'type asc' ],
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'type' => 'invalidArguments',
        'description' => 'no sinceState given',
      },
      "No sinceState - correct error",
    );
  }

  {
    # sinceState up to date
    $res = $jmap_tester->request([
      [
        getCakeListUpdates => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'type asc' ],
          sinceState => $state,
        },
      ],
    ]);

    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'added' => [],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
        },
        'newState' => jstr($state),
        'oldState' => jstr($state),
        'removed' => [],
        'sort' => [
          'type asc'
        ],
        'total' => 2
      },
      "getCakeListUpdates looks right for no changes"
    );
  }

  {
    # Update a cake
    $res = $jmap_tester->request([
      [
        setCakes => {
          update => {
            $cake_id{pb1} => { layer_count => 9 },
          },
        },
      ],
    ]);

    jcmp_deeply(
      [ $res->single_sentence->as_set->updated_ids() ],
      [ "$cake_id{pb1}", ],
      'upgraded a cake'
    ) or diag explain $res->as_stripped_struct;

    $state++;
  }

  # And now check state
  {
    $res = $jmap_tester->request([
      [
        getCakeListUpdates => {
          filter => {
            recipeId => $secret1_recipe_id,
          },
          sort => [ 'type asc' ],
          sinceState => $state-1,
        },
      ],
    ]);

    # a remove/add will appear for the same cake id
    jcmp_deeply(
      $res->single_sentence->arguments,
      {
        'added' => [
          {
            'cakeId' => $cake_id{pb1},
            'index' => 1,
          },
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
        },
        'newState' => $state,
        'oldState' => $state-1,
        'removed' => [
          $cake_id{pb1},
        ],
        'sort' => [
          'type asc'
        ],
        'total' => 2
      },
      "getCakeListUpdates looks right for no changes"
    );
  }

  {
    # Hooks
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId => 'secret',
          },
        },
      ],
      [
        getCakeListUpdates => {
          filter => {
            recipeId => 'secret',
          },
          sinceState => $state-1,
        },
      ],
    ]);

    jcmp_deeply(
      $res->sentence(0)->arguments,
      {
        type        => 'invalidArguments',
        description => "That recipe is too secret for you",
      },
      "getCakeList ix_get_list_check hook works"
    );

    jcmp_deeply(
      $res->sentence(1)->arguments,
      {
        type        => 'invalidArguments',
        description => "That recipe is way too secret for you",
      },
      "getCakeListUpdates ix_get_list_updates_check hook works"
    );
  }

  {
    # fetchFooProperties
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId   => $secret1_recipe_id,
            type       => 'peanut butter',
          },
          fetchCakes => \1,
          fetchCakeProperties => [ 'type', 'baked_at' ],
        },
      ],
    ]);

    jcmp_deeply(
      $res->sentence(0)->arguments,
      {
        'cakeIds' => [
          @cake_id{qw(pb1)},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
          'type'     => 'peanut butter',
        },
        'canCalculateUpdates' => JSON::MaybeXS::JSON->true,
        'position' => 0,
        'sort' => undef,
        'state' => $state,
        'total' => 1,
      },
      "getCakeList with fetchRecipes => 1 but no fetchCakes"
    ) or diag explain $res->as_stripped_struct;

    jcmp_deeply(
      $res->sentence(1)->arguments->{list},
      [
        {
          id       => $cake_id{pb1},
          type     => 'peanut butter',
          baked_at => ignore(),
        },
      ],
      "got cake back with fetchCakes => 1"
    ) or diag explain $res->as_stripped_struct;

    # fetchOtherFooProperties
    $res = $jmap_tester->request([
      [
        getCakeList => {
          filter => {
            recipeId   => $secret1_recipe_id,
            type       => 'peanut butter',
          },
          fetchRecipes => \1,
          fetchRecipeProperties => [ 'is_delicious' ],
        },
      ],
    ]);

    jcmp_deeply(
      $res->sentence(0)->arguments,
      {
        'cakeIds' => [
          @cake_id{qw(pb1)},
        ],
        'filter' => {
          'recipeId' => $secret1_recipe_id,
          'type'     => 'peanut butter',
        },
        'canCalculateUpdates' => JSON::MaybeXS::JSON->true,
        'position' => 0,
        'sort' => undef,
        'state' => $state,
        'total' => 1,
      },
      "getCakeList with fetchRecipes => 1 but no fetchCakes"
    ) or diag explain $res->as_stripped_struct;

    jcmp_deeply(
      $res->sentence(1)->arguments->{list},
      [
        {
          id           => $secret1_recipe_id,
          is_delicious => jtrue,
        },
      ],
      "got recipe back with no fetchCakes and fetchRecipes => 1"
    ) or diag explain $res->as_stripped_struct;
  }

  subtest 'custom differ, and no required filters' => sub {
    # Ensure our custom differ works. Also ensure that if we don't have
    # required filters, we limit our updates list to those that could
    # have changed, not the entire table

    my @states;

    my %cl_args = (
      filter => {
        types => [ 'oatmeal stout', 'oreo stout' ],
        batch => $Bakesale::Schema::Result::Cookie::next_batch,
      },
      sort   => [ "type asc" ],
    );

    {
      # Get base state
      my $cl_res = $jmap_tester->request([[
        getCookieList => \%cl_args,
      ]]);

      jcmp_deeply(
        $cl_res->single_sentence->arguments,
        superhashof({
          cookieIds => [],
        }),
        "No cookies match our filter yet"
      ) or diag explain $cl_res->as_stripped_struct;

      my $base_state = $cl_res->single_sentence->arguments->{state};
      ok(defined $base_state, 'got cookie state');

      push @states, $base_state;
    }

    my ($oatmeal, $oreo, $peanut);

    {
      # Create some weird cookies
      my $set_cookies = $jmap_tester->request([
        [ setCookies => { create => {
          oatmeal1 => { type => 'oatmeal stout' },
          oreo1    => { type => 'oreo stout'    },
          peanut1  => { type => 'peanut stout'  },
        } } ],
      ]);

      my $set = $set_cookies->sentence(0)->as_set;

      is(
        $set->created_ids,
        3,
        'created 3 cookies'
      ) or diag explain $set_cookies->as_stripped_struct;

      $oatmeal = $set->created_id('oatmeal1') . "";
      $oreo = $set->created_id('oreo1') . "";
      $peanut = $set->created_id('peanut1') . "";

      # Verify
      my $clu_res = $jmap_tester->request([[
        getCookieListUpdates => {
          %cl_args,
          sinceState => $states[0],
        },
      ]]);

      jcmp_deeply(
        $clu_res->single_sentence->arguments,
        superhashof({
          added => [
            {
              index => 0,
              cookieId => $oatmeal,
            }, {
              index => 1,
              cookieId => $oreo,
            }
          ],
          removed => [ ],
        }),
        "Got two cookies out of three"
      ) or diag explain $clu_res->as_stripped_struct;

      my $state = $clu_res->single_sentence->arguments->{newState};
      ok(defined $state, 'got next cookie state')
        or diag explain $clu_res->as_stripped_struct;

      cmp_ok($state, '>', $states[-1], 'cookie state increased');

      push @states, $state;
    }

    {
      # Change two cookies, one so it no longer matches the filter, another
      # so it now matches the filter
      my $upd_res = $jmap_tester->request([[
        setCookies => {
          update => {
            $oatmeal => { type => 'banana' },
            $peanut  => { type => 'oatmeal stout' },
          },
        },
      ]]);

      is(
        $upd_res->single_sentence->as_set->updated_ids,
        2,
        'updated the type of two cookies'
      );

      # Verify
      my $clu_res = $jmap_tester->request([[
        getCookieListUpdates => {
          %cl_args,
          sinceState => $states[-1],
        },
      ]]);

      jcmp_deeply(
        $clu_res->single_sentence->arguments,
        superhashof({
          added => [
            {
              index => 0,
              cookieId => $peanut,
            },
          ],
          removed => [
            $oatmeal,
            $peanut # Spurious remove, but spec says that's okay
          ],
        }),
        "Correctly reported addition of 1 cookie and removal of another"
      ) or diag explain $clu_res->as_stripped_struct;
    }
  };

  subtest "filters on joined tables" => sub {
    subtest "filter matches" => sub {
      $res = $jmap_tester->request([
        [
          getCakeList => {
            filter => {
              'recipeId' => $secret1_recipe_id,
              'recipe.is_delicious' => jtrue,
            },
            sort => [ 'type asc' ],
          },
        ],
      ]);

      jcmp_deeply(
        $res->single_sentence->arguments,
        {
          'cakeIds' => [
            $cake_id{chocolate2},
            $cake_id{pb1},
          ],
          'filter' => {
            'recipeId' => $secret1_recipe_id,
            'recipe.is_delicious' => jtrue,

          },
          'canCalculateUpdates' => jtrue,
          'position' => 0,
          'sort' => [
            'type asc',
          ],
          'state' => $state,
          'total' => 2,
        },
        "getCakeList with filter on join with match looks right"
      ) or diag explain $res->as_stripped_struct;

      $res = $jmap_tester->request([
        [
          getCakeListUpdates => {
            filter => {
              recipeId => $secret1_recipe_id,
              'recipe.is_delicious' => jtrue,
            },
            sort => [ 'type asc' ],
            sinceState => $state - 3,
          },
        ],
      ]);

      jcmp_deeply(
        $res->single_sentence->arguments,
        {
          'added' => [
            {
              'cakeId' => $cake_id{chocolate2},
              'index' => 0,
            },
            {
              'cakeId' => $cake_id{pb1},
              'index' => 1,
            }
          ],
          'filter' => {
            'recipeId' => $secret1_recipe_id,
            'recipe.is_delicious' => jtrue,
          },
          'newState' => $state,
          'oldState' => $state - 3,
          'removed' => [],
          'sort' => [
            'type asc'
          ],
          'total' => 2
        },
        "getCakeListUpdates with filter on join with match looks right"
      ) or diag explain $res->as_stripped_struct;
    };

    subtest "filter doesn't match" => sub {
      $res = $jmap_tester->request([
        [
          getCakeList => {
            filter => {
              'recipeId' => $secret1_recipe_id,
              'recipe.is_delicious' => jfalse, # But these are delicious!
            },
            sort => [ 'type asc' ],
          },
        ],
      ]);

      jcmp_deeply(
        $res->single_sentence->arguments,
        {
          'cakeIds' => [],
          'filter' => {
            'recipeId' => $secret1_recipe_id,
            'recipe.is_delicious' => jfalse,
          },
          'canCalculateUpdates' => jtrue,
          'position' => 0,
          'sort' => [
            'type asc',
          ],
          'state' => $state,
          'total' => 0,
        },
        "getCakeList with filter on join no match looks right"
      ) or diag explain $res->as_stripped_struct;

      $res = $jmap_tester->request([
        [
          getCakeListUpdates => {
            filter => {
              recipeId => $secret1_recipe_id,
              'recipe.is_delicious' => jfalse,
            },
            sort => [ 'type asc' ],
            sinceState => $state - 3,
          },
        ],
      ]);

      jcmp_deeply(
        $res->single_sentence->arguments,
        superhashof({
          added    => [],
          removed  => [],
          total    => 0,
          newState => $state,
          oldState => $state - 3,
          filter => {
            recipeId => $secret1_recipe_id,
            'recipe.is_delicious' => jfalse,
          },
          total => 0,
        }),
        "getCakeListUpdates with filter on join no match looks right"
      );
    };
  };

  subtest "differ boolean comparison when db row is false" => sub {
    # The above test ensured we matched booleans properly when the DB
    # value is true and the filter is true/false, this test ensures
    # we handle things properly when the DB value is false and the filter
    # is true/false
    subtest "filter is false" => sub {
      $res = $jmap_tester->request([
        [
          getCakeListUpdates => {
            filter => {
              recipeId => $secret2_recipe_id,
              'recipe.is_delicious' => jfalse,
            },
            sort => [ 'type asc' ],
            sinceState => $state - 3,
          },
        ],
      ]);

      jcmp_deeply(
        $res->single_sentence->arguments,
        {
          'added' => set(
            superhashof({
              'cakeId' => $cake_id{marble1},
            }),
            superhashof({
              'cakeId' => $cake_id{marble2},
              'index'  => ignore(),
            }),
            superhashof({
              'cakeId' => $cake_id{lemon1},
              'index'  => ignore(),
            }),
          ),
          'filter' => {
            'recipeId' => $secret2_recipe_id,
            'recipe.is_delicious' => jfalse,
          },
          'newState' => $state,
          'oldState' => $state - 3,
          'removed' => [],
          'sort' => [
            'type asc'
          ],
          'total' => 3,
        },
        "getCakeListUpdates with filter on join with match looks right"
      ) or diag explain $res->as_stripped_struct;
    };

    subtest "filter is true" => sub {
      # Starting at state 0, the rows were added and removed, so
      # we should see no changes
      $res = $jmap_tester->request([
        [
          getCakeListUpdates => {
            filter => {
              recipeId => $secret2_recipe_id,
              'recipe.is_delicious' => jtrue,
            },
            sort => [ 'type asc' ],
            sinceState => $state - 3,
          },
        ],
      ]);

      jcmp_deeply(
        $res->single_sentence->arguments,
        {
          'added' => [],
          'filter' => {
            'recipeId' => $secret2_recipe_id,
            'recipe.is_delicious' => jtrue,
          },
          'newState' => $state,
          'oldState' => $state - 3,
          'removed' => [],
          'sort' => [
            'type asc'
          ],
          'total' => 0,
        },
        "getCakeListUpdates with filter on join with no match looks right"
      ) or diag explain $res->as_stripped_struct;

      # Now from the state where they were added, we should see removed
      $res = $jmap_tester->request([
        [
          getCakeListUpdates => {
            filter => {
              recipeId => $secret2_recipe_id,
              'recipe.is_delicious' => jtrue,
            },
            sort => [ 'type asc' ],
            sinceState => $state - 2,
          },
        ],
      ]);

      jcmp_deeply(
        $res->single_sentence->arguments,
        {
          'added' => [],
          'filter' => {
            'recipeId' => $secret2_recipe_id,
            'recipe.is_delicious' => jtrue,
          },
          'newState' => $state,
          'oldState' => $state - 2,
          'removed' => set(
            $cake_id{marble1},
            $cake_id{marble2},
            $cake_id{lemon1},
          ),
          'sort' => [
            'type asc'
          ],
          'total' => 0,
        },
        "getCakeListUpdates with filter on join with no match looks right"
      ) or diag explain $res->as_stripped_struct;
    };
  };

  subtest "distinct rows only" => sub {
    # If a cake has many toppers it should still only come back once
    my $res = $jmap_tester->request([[ setCakeToppers => {
      create => {
        first  => { cakeId => $cake_id{pb1}, type => 'sprinkles' },
        second => { cakeId => $cake_id{pb1}, type => 'candles'   },
      },
    } ]]);

    is($res->single_sentence->as_set->created_ids, 2, 'created toppers');

    # This causes our generated SQL to allow for duplicate rows which
    # can happen in downstream consumers
    $ENV{RECIPEID_NOT_REQUIRED} = 1;

    delete $cake_id{chocolate1};

    $res = $jmap_tester->request([
      [
        getCakeList => {
          sort => [ 'id asc' ],
        },
      ],
    ]);
    jcmp_deeply(
      $res->single_sentence->arguments,
      superhashof({
        cakeIds => [
          sort { $a cmp $b } values %cake_id,
        ],
        total => 5,
      }),
      "no duplicates in getFooList"
    ) or diag explain $res->as_stripped_struct;

    $res = $jmap_tester->request([
      [
        getCakeListUpdates => {
          sort => [ 'id asc' ],
          sinceState => 0,
        },
      ],
    ]);
    jcmp_deeply(
      $res->single_sentence->arguments,
      superhashof({
        added => [
          map {;
            {
              index  => ignore(),
              cakeId => $_
            },
          } sort { $a cmp $b } values %cake_id,
        ],
        total => 5,
      }),
      "no duplicates in getFooListUpdates"
    ) or diag explain $res->as_stripped_struct;
  };

  subtest "tooManyChanges" => sub {
    subtest "Plenty of space for more changes" => sub {
      my $res = $jmap_tester->request([[
        getCakeListUpdates => {
          sinceState => 1,
          maxChanges => 100,
        },
      ]]);

      jcmp_deeply(
        $res->sentence(0)->arguments,
        superhashof({
          added => [ superhashof({ index => ignore() }) ],
          removed => [ ignore(), ignore() ],
        }),
        'got a good response, with both added/removed elements'
      );
    };

    subtest "Exact amount of changes" => sub {
      my $res = $jmap_tester->request([[
        getCakeListUpdates => {
          sinceState => 1,
          maxChanges => 3,
        },
      ]]);

      jcmp_deeply(
        $res->sentence(0)->arguments,
        superhashof({
          added => [ superhashof({ index => ignore() }) ],
          removed => [ ignore(), ignore() ],
        }),
        'got a good response, with both added/removed elements'
      );
    };

    subtest "Not enough room for all the changes" => sub {
      my $res = $jmap_tester->request([[
        getCakeListUpdates => {
          sinceState => 1,
          maxChanges => 2,
        },
      ]]);

      is(
        $res->sentence(0)->arguments->{type},
        'tooManyChanges',
        'got correct error'
      ) or diag explain $res->as_stripped_struct;
    };
  };
};

done_testing;
