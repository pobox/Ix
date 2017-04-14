use 5.20.0;
use warnings;
use experimental qw(signatures postderef);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use Test::Deep;
use Test::Deep::JType;
use Test::More;
use Test::Abortable;

{
  my ($test_env) = Bakesale::Test->new_test_env;
  my ($app, $jmap_tester) = $test_env->@{qw(app tester)};

  my ($admin_id, $accountId) = Bakesale::Test->load_single_user(
    $app->processor->schema_connection
  );
  $jmap_tester->_set_cookie('bakesaleUserId', $admin_id);

  # Set our base state to 1-1 so we can ensure we're told to resync if we
  # pass in a sinceState lower than that (0-1 or 1-0 for example).
  my $updated = $app->processor->schema_connection->resultset('State')->search({
    accountId => $accountId,
    type      => [ qw(cakes cakeRecipes) ],
  })->update({
    lowestModSeq  => 1,
    highestModSeq => 1,
  });
  is($updated, 2, 'updated two state rows');

  subtest "simple state comparisons" => sub {
    # First up, we are going to set up fudge distinct states, each with 10
    # updates. -- rjbs, 2016-05-03
    my $last_set_res;
    for my $type (qw(sugar anzac spritz fudge)) {
      $last_set_res = $jmap_tester->request([
        [
          setCookies => {
            create => { map {; $_ => { type => $type } } (1 .. 10) }
          }
        ],
      ]);
    }

    my $state = $last_set_res->single_sentence->as_set->new_state . "";

    subtest "synchronize to current state: no-op" => sub {
      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => "4" } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'cookieUpdates', 'cookie updates!!');

      is($arg->{oldState}, 4, "old state: 4");
      is($arg->{newState}, 4, "new state: 4");
      ok( ! $arg->{hasMoreUpdates}, "no more updates");
      ok(! $arg->{changed}->@*, "no items changed");
      ok(! $arg->{removed}->@*, "no items removed");
    };

    subtest "synchronize from lowest state on file" => sub {
      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => "0" } ]
      ]);

      ok($res->as_struct->[0][1]{changed}->@*, 'can sync from "0" state');
    };

    subtest "synchronize from the future" => sub {
      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => "8" } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'error', 'can not sync from future state');

      is($arg->{type}, "invalidArguments", "error type");
    };

    subtest "synchronize (2 to 4), no maxChanges" => sub {
      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => "2" } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'cookieUpdates', 'cookie updates!!');

      is($arg->{oldState}, 2, "old state: 2");
      is($arg->{newState}, 4, "new state: 4");
      ok( ! $arg->{hasMoreUpdates}, "no more updates");
      is($arg->{changed}->@*, 20, "20 items changed");
      ok(! $arg->{removed}->@*,   "no items removed");
    };

    subtest "synchronize (2 to 4), maxChanges exceeds changes" => sub {
      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => "2", maxChanges => 30 } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'cookieUpdates', 'cookie updates!!');

      is($arg->{oldState}, 2, "old state: 2");
      is($arg->{newState}, 4, "new state: 4");
      ok( ! $arg->{hasMoreUpdates}, "no more updates");
      is($arg->{changed}->@*, 20, "20 items changed");
      ok(! $arg->{removed}->@*,   "no items removed");
    };

    subtest "synchronize (2 to 4), maxChanges equals changes" => sub {
      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => "2", maxChanges => 20 } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'cookieUpdates', 'cookie updates!!');

      is($arg->{oldState}, 2, "old state: 2");
      is($arg->{newState}, 4, "new state: 4");
      ok( ! $arg->{hasMoreUpdates}, "no more updates");
      is($arg->{changed}->@*, 20, "20 items changed");
      ok(! $arg->{removed}->@*,   "no items removed");
    };

    subtest "synchronize (2 to 4), maxChanges requires truncation" => sub {
      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => "2", maxChanges => 15 } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'cookieUpdates', 'cookie updates!!');

      is($arg->{oldState}, 2, "old state: 2");
      is($arg->{newState}, 3, "new state: 3");
      ok($arg->{hasMoreUpdates},   "more updates to get");
      is($arg->{changed}->@*, 10, "10 items changed");
      ok(! $arg->{removed}->@*,   "no items removed");
    };

    subtest "synchronize (2 to 4), maxChanges must be exceeded" => sub {
      my $res = $jmap_tester->request([
        [ getCookieUpdates => { sinceState => "2", maxChanges => 8 } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'cookieUpdates', 'cookie updates!!');

      is($arg->{oldState}, 2, "old state: 2");
      is($arg->{newState}, 3, "new state: 3");
      ok($arg->{hasMoreUpdates},   "more updates to get");
      is($arg->{changed}->@*, 10, "10 items changed");
      ok(! $arg->{removed}->@*,   "no items removed");
    };
  };

  subtest "complex state comparisons" => sub {
    # Okay, here we're going to have two kinds of results, where changing the
    # parent row causes the child to seem out of sync.  Specifically, we have
    # Cakes and CakeRecipes.  If a cake changes, it has changed.  If a recipe has
    # changed, all the cakes of that recipe are also changed.  This is a rough
    # approximation of the logic that will govern mailing list members and lists.
    # -- rjbs, 2016-05-04
    my %recipe_id;
    subtest "create 5 recipes" => sub {
      for my $n (1..5) {
        my $cr_res = $jmap_tester->request([
          [
            setCakeRecipes => {
              create => { $n => { type => "recipe-$n", avg_review => 75 } }
            },
          ],
        ]);

        my $recipe_res = $jmap_tester->strip_json_types(
          $cr_res->single_sentence->as_struct->[1]
        );

        $recipe_id{$n} = $recipe_res->{created}{$n}{id};

        my $cr_state = $cr_res->single_sentence->as_set->new_state . "";
        is($cr_state, $n+1, "after creating recipe $n, state is " . ($n + 1));
      }
    };

    my %cake_id;
    subtest "create 20 cakes" => sub {
      my $last_set_res;
      for my $layer_count (1 .. 4) {
        $last_set_res = $jmap_tester->request([
          [
            setCakes => {
              create => { map {; $_ => {
                type     => "test $layer_count/$_",
                recipeId => $recipe_id{$_},
                layer_count => $layer_count,
              } } (1 .. 5) }
            }
          ],
        ]);

        my $payload = $jmap_tester->strip_json_types(
          $last_set_res->single_sentence->as_struct->[1]
        );

        for my $recipe (1 .. 5) {
          $cake_id{"C${layer_count}R$recipe"}
            = $payload->{created}{$recipe}{id};
        }
      }

      my $state = $last_set_res->single_sentence->as_set->new_state . "";
      is($state, "5-6", "four cake sets on recipe state 5; state is 5-6");
    };

    my %cake_id_rev = reverse %cake_id;

    subtest "synchronize to current state: no-op" => sub {
      my $res = $jmap_tester->request([
        [ getCakeUpdates => { sinceState => "5-6" } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'cakeUpdates', 'cake updates!!');

      is($arg->{oldState}, '5-6', "old state: 5-6");
      is($arg->{newState}, '5-6', "new state: 5-6");
      ok( ! $arg->{hasMoreUpdates}, "no more updates");
      ok(! $arg->{changed}->@*, "no items changed");
      ok(! $arg->{removed}->@*, "no items removed");
    };

    subtest "synchronize from non-compound state" => sub {
      my $res = $jmap_tester->request([
        [ getCakeUpdates => { sinceState => "2" } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'error', 'can not sync from non-compount state');

      is($arg->{type}, "invalidArguments", "error type");
    };

    subtest "synchronize from too-low lhs state" => sub {
      my $res = $jmap_tester->request([
        [ getCakeUpdates => { sinceState => "0-3" } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'error', 'can not sync from (one-part) too-low state');

      is($arg->{type}, "cannotCalculateChanges", "error type");
    };

    subtest "synchronize from too-low rhs state" => sub {
      my $res = $jmap_tester->request([
        [ getCakeUpdates => { sinceState => "3-0" } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'error', 'can not sync from (one-part) too-low state');

      is($arg->{type}, "cannotCalculateChanges", "error type");
    };

    subtest "synchronize (4-6 to 5-6), no maxChanges" => sub {
      my $res = $jmap_tester->request([
        [ getCakeUpdates => { sinceState => "4-6" } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'cakeUpdates', 'cake updates!!');

      is($arg->{oldState}, '4-6', "old state: 4-6");
      is($arg->{newState}, '5-6', "new state: 5-6");
      ok( ! $arg->{hasMoreUpdates}, "no more updates");
      is($arg->{changed}->@*, 5, "5 items changed");

      is_deeply(
        [ sort $arg->{changed}->@* ],
        [ sort @cake_id{qw( C4R1 C4R2 C4R3 C4R4 C4R5 )} ],
        "the five expected items updated",
      );

      ok(! $arg->{removed}->@*,   "no items removed");
    };

    subtest "synchronize (5-5 to 5-6), no maxChanges" => sub {
      my $res = $jmap_tester->request([
        [ getCakeUpdates => { sinceState => "5-5" } ]
      ]);

      my ($type, $arg) = $res->single_sentence->as_struct->@*;
      is($type, 'cakeUpdates', 'cake updates!!');

      is($arg->{oldState}, '5-5', "old state: 5-5");
      is($arg->{newState}, '5-6', "new state: 5-6");
      ok( ! $arg->{hasMoreUpdates}, "no more updates");
      is($arg->{changed}->@*, 4, "4 items changed");

      is_deeply(
        [ sort $arg->{changed}->@* ],
        [ sort @cake_id{qw( C1R5 C2R5 C3R5 C4R5 )} ],
        "the five expected items updated",
      );

      ok(! $arg->{removed}->@*,   "no items removed");
    };

    for my $test (
      [ "sync (4-5 to 5-6), no maxChanges",              {} ],
      [ "sync (4-5 to 5-6), maxChanges exceeds updates", { maxChanges => 10 } ],
      [ "sync (4-5 to 5-6), maxChanges qeuals updates",  { maxChanges =>  8 } ],
    ) {
      subtest $test->[0] => sub {
        my $res = $jmap_tester->request([
          [ getCakeUpdates => { sinceState => "4-5", $test->[1]->%* } ]
        ]);

        my ($type, $arg) = $res->single_sentence->as_struct->@*;
        is($type, 'cakeUpdates', 'cake updates!!');

        is($arg->{oldState}, '4-5', "old state: 4-5");
        is($arg->{newState}, '5-6', "new state: 5-6");
        ok( ! $arg->{hasMoreUpdates}, "no more updates");
        is($arg->{changed}->@*, 8, "8 items changed");

        is_deeply(
          [ sort $arg->{changed}->@* ],
          [ sort @cake_id{qw( C4R1 C4R2 C4R3 C4R4 C4R5
                              C1R5 C2R5 C3R5 )} ],
          "the eight expected items updated",
        );

        ok(! $arg->{removed}->@*,   "no items removed");
      };
    }

    subtest "sync (4-5 to 5-6), maxChanges forces 2 passes" => sub {
      my %changed;
      my $mid_state;
      subtest "first pass at small-window update" => sub {
        my $res = $jmap_tester->request([
          [ getCakeUpdates => { sinceState => "4-5", maxChanges => 5 } ]
        ]);

        my ($type, $arg) = $res->single_sentence->as_struct->@*;
        is($type, 'cakeUpdates', 'cake updates!!');

        is($arg->{oldState}, '4-5', "old state: 4-5");
        ok(
          $arg->{newState} ne $arg->{oldState},
          "new state: $arg->{newState}",
        );
        ok($arg->{hasMoreUpdates},  "more updates await");
        ok(! $arg->{removed}->@*,   "no items removed");

        my @changed = $arg->{changed}->@*;
        cmp_ok(@changed, '<=', 5, "<= 5 items changed");

        $changed{ $cake_id_rev{$_} }++ for @changed;
        $mid_state = $arg->{newState};
      };

      subtest "second pass at small-window update" => sub {
        my $res = $jmap_tester->request([
          [ getCakeUpdates => { sinceState => $mid_state, maxChanges => 5 } ]
        ]);

        my ($type, $arg) = $res->single_sentence->as_struct->@*;
        is($type, 'cakeUpdates', 'cake updates!!');

        is($arg->{oldState}, $mid_state, "old state: $mid_state");
        ok(! $arg->{hasMoreUpdates},  "no more updates");
        ok(! $arg->{removed}->@*,   "no items removed");

        my @changed = $arg->{changed}->@*;
        cmp_ok(@changed, '<=', 5, "<= 5 items changed");

        $changed{ $cake_id_rev{$_} }++ for $arg->{changed}->@*;
      };

      is(keys %changed, 8, "eight total updates (with maybe some dupes)");
      is_deeply(
        [ sort keys %changed ],
        [ sort qw( C4R1 C4R2 C4R3 C4R4 C4R5 C1R5 C2R5 C3R5 ) ],
        "the eight expected items updated",
      );
    };

    subtest "sync (4-5 to 5-6), maxChanges smaller than first window" => sub {
      my %changed;
      my $mid_state;
      subtest "first pass at small-window update" => sub {
        my $res = $jmap_tester->request([
          [ getCakeUpdates => { sinceState => "4-5", maxChanges => 3 } ]
        ]);

        my ($type, $arg) = $res->single_sentence->as_struct->@*;
        is($type, 'cakeUpdates', 'cake updates!!');

        is($arg->{oldState}, '4-5', "old state: 4-5");
        ok(
          $arg->{newState} ne $arg->{oldState},
          "new state: $arg->{newState}",
        );
        ok($arg->{hasMoreUpdates},  "more updates await");
        ok(! $arg->{removed}->@*,   "no items removed");

        my @changed = $arg->{changed}->@*;
        cmp_ok(@changed, '<=', 5, "<= 5 items changed");

        $changed{ $cake_id_rev{$_} }++ for @changed;
        $mid_state = $arg->{newState};
      };

      subtest "second pass at small-window update" => sub {
        my $res = $jmap_tester->request([
          [ getCakeUpdates => { sinceState => $mid_state, maxChanges => 5 } ]
        ]);

        my ($type, $arg) = $res->single_sentence->as_struct->@*;
        is($type, 'cakeUpdates', 'cake updates!!');

        is($arg->{oldState}, $mid_state, "old state: $mid_state");
        ok(! $arg->{hasMoreUpdates},  "no more updates");
        ok(! $arg->{removed}->@*,   "no items removed");

        my @changed = $arg->{changed}->@*;
        cmp_ok(@changed, '<=', 5, "<= 5 items changed");

        $changed{ $cake_id_rev{$_} }++ for $arg->{changed}->@*;
      };

      is(keys %changed, 8, "eight total updates (with maybe some dupes)");
      is_deeply(
        [ sort keys %changed ],
        [ sort qw( C4R1 C4R2 C4R3 C4R4 C4R5 C1R5 C2R5 C3R5 ) ],
        "the eight expected items updated",
      );
    };
  };

  subtest "updated null and updated Object" => sub {
    my $cookie_id;

    {
      my $res = $jmap_tester->request([
        [
          setCookies => {
            create => { foo => { type => 'macaroon' } }
          },
        ],
      ]);

      my $set = $res->assert_successful->single_sentence('cookiesSet')->as_set;
      my $cookie = $set->created->{foo};
      $cookie_id = $cookie->{id};

      jcmp_deeply(
        $cookie,
        {
          id => jstr(),
          baked_at => ignore(),
          expires_at => ignore(),
          delicious => jstr('yes'),
          batch => ignore,
          external_id => undef, # is this really needed?
        },
        "created a cookie"
      );
    }

    {
      my $res = $jmap_tester->request([
        [
          setCookies => {
            update => { $cookie_id => { delicious => 'maybe' } }
          },
        ],
      ]);

      my $set = $res->assert_successful->single_sentence('cookiesSet')->as_set;
      my $cookie = $set->updated->{ $cookie_id };

      jcmp_deeply(
        $cookie,
        undef,
        "we updated the cookie, no server-provided updates",
      );
    }

    {
      my $res = $jmap_tester->request([
        [
          setCookies => {
            update => { $cookie_id => { type => 'macaron' } }
          },
        ],
      ]);

      my $set = $res->assert_successful->single_sentence('cookiesSet')->as_set;
      my $cookie = $set->updated->{ $cookie_id };

      jcmp_deeply(
        $cookie,
        { delicious => jstr('eh') },
        "we updated the cookie, so did the server",
      );
    }
  };
};

done_testing;
