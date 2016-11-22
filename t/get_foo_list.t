use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use JSON;
use Test::Deep;
use Test::Deep::JType;
use Test::More;
use Unicode::Normalize;

my ($app, $jmap_tester) = Bakesale::Test->new_test_app_and_tester;
\my %account = Bakesale::Test->load_trivial_account($app->processor->schema_connection);

$jmap_tester->_set_cookie('bakesaleUserId', $account{users}{rjbs});

# Create some recipes
my $res = $jmap_tester->request([
  [
    setCakeRecipes => {
      create => {
        secret1 => {
          type          => 'secret1',
          avg_review    => 0,
          is_delicious  => \1,
        },
        secret2 => {
          type          => 'secret2',
          avg_review    => 0,
          is_delicious  => \1,
        },
      },
    },
  ],
]);

my $secret1_recipe_id = $res->single_sentence->as_set->created_id('secret1');
my $secret2_recipe_id = $res->single_sentence->as_set->created_id('secret2');

ok($secret1_recipe_id, 'created a chocolate recipe');
ok($secret2_recipe_id, 'created a marble recipe');

# Now create a few cakes under each one
$res = $jmap_tester->request([
  [
    setCakes => {
      create => {
        'chocolate1' => {
          type => 'chocolate', layer_count => 2, recipeId => $secret1_recipe_id,
        },
        'chocolate2' => {
          type => 'chocolate', layer_count => 3, recipeId => $secret1_recipe_id,
        },
        'pb1' => {
          type => 'peanut butter', layer_count => 3, recipeId => $secret1_recipe_id,
        },
        'marble1' => {
          type => 'marble', layer_count => 2, recipeId => $secret2_recipe_id,
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
        ( sort { $a <=> $b } @cake_id{qw(chocolate1 chocolate2)} ),
        $cake_id{pb1},
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id
      },
      'canCalculateUpdates' => JSON::true,
      'position' => 0,
      'sort' => [
        'type asc',
      ],
      'state' => $state,
      'total' => 3,
    },
    "getCakeList with sort+filter looks right"
  );

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
        ( sort { $a <=> $b } @cake_id{qw(chocolate1 chocolate2)} ),
      ],
      'filter' => {
        'recipeId' => $secret1_recipe_id
      },
      'canCalculateUpdates' => JSON::true,
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
      'canCalculateUpdates' => JSON::true,
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
      'canCalculateUpdates' => JSON::true,
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
      'canCalculateUpdates' => JSON::true,
      'position' => 0,
      'sort' => [
      ],
      'state' => $state,
      'total' => 1,
    },
    "getCakeList with no sort, multi-filter"
  );
}

{
  # Pagination
  my $p = 0;

  for my $cid (sort { $a <=> $b } @cake_id{qw(chocolate1 chocolate2 pb1)}) {
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
        'canCalculateUpdates' => JSON::true,
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
        fetchCakes => \1,
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
      'canCalculateUpdates' => JSON::true,
      'position' => 0,
      'sort' => [
      ],
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

  # This fetch arg is useless without the first.
  # XXX - Throw error? -- alh, 2016-11-22
  $res = $jmap_tester->request([
    [
      getCakeList => {
        filter => {
          recipeId   => $secret1_recipe_id,
          type       => 'peanut butter',
        },
        fetchRecipes => \1,
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
      'canCalculateUpdates' => JSON::true,
      'position' => 0,
      'sort' => [
      ],
      'state' => $state,
      'total' => 1,
    },
    "getCakeList with fetchRecipes => 1 but no fetchCakes doesn't grab recipes"
  ) or diag explain $res->as_stripped_struct;

  # Provide both
  $res = $jmap_tester->request([
    [
      getCakeList => {
        filter => {
          recipeId   => $secret1_recipe_id,
          type       => 'peanut butter',
        },
        fetchCakes   => \1,
        fetchRecipes => \1,
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
      'canCalculateUpdates' => JSON::true,
      'position' => 0,
      'sort' => [
      ],
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
        fetchCakes   => \1,
        fetchRecipes => \1,
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
      'canCalculateUpdates' => JSON::true,
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
      'newState' => $state,
      'oldState' => $state-2,
      'removed' => [],
      'sort' => [
        'type asc'
      ],
      'total' => 2
    },
    "getCakeListUpdates looks right for added cakes"
  );

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
      'newState' => $state,
      'oldState' => $state-1,
      'removed' => [
        $cake_id{chocolate1},
      ],
      'sort' => [
        'type asc'
      ],
      'total' => 2
    },
    "getCakeListUpdates looks right for removed cake"
  );
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
      'newState' => $state,
      'oldState' => $state,
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
    [ $cake_id{pb1}, ],
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

done_testing;

