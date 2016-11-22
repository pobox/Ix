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

{
  $app->clear_transaction_log;

  # setCakes/create setCakes/update getCakes can mask secret fields
  my $res = $jmap_tester->request([
    [
      setCakes => {
        create    => {
          yum => { type => 'layered', phrase => "happy birthday", layer_count => 4, recipeId => $account{recipes}{1} },
        }
      },
    ]
  ]);

  my $id = $res->single_sentence->as_set->created_id('yum');
  ok($id, 'created a cake');

  jcmp_deeply(
    $res->single_sentence->as_set->arguments->{created},
    {
      yum => {
        baked_at => ignore(),
        id       => ignore()
      },
    },
    'created structure looks right'
  );

  # Verify
  $res = $jmap_tester->request([
    [
      getCakes => {
        ids => [ $id ],
      },
    ],
  ]);

  is(
    $res->single_sentence->arguments->{list}[0]{phrase},
    'happy birthday',
    'phrase is correct'
  );

  $res = $jmap_tester->request([
    [
      setCakes => {
        update => {
          $id => { phrase => "happy birthday you" },
        },
      },
    ]
  ]);

  cmp_deeply(
    [ $res->single_sentence->as_set->updated_ids ],
    [ $id ],
    'item updated'
  );

  # verify 
  $res = $jmap_tester->request([
    [
      getCakes => {
        ids => [ $id ],
      },
    ],
  ]);

  is(
    $res->single_sentence->arguments->{list}[0]{phrase},
    'happy birthday you',
    'phrase is correct'
  );

  my @xacts = $app->drain_transaction_log;
  is(@xacts, 4, "we log transactions (at least when testing)");

  for my $log (@xacts) {
    my $req = $log->{request};
    ok($req, 'got a logged request');

    if ($req =~ /setCakes/) {
      like($req, qr/\Q"phrase":"***MASKED***"\E/, 'got a masked req');
    } else {
      unlike($req, qr/\Qphrase\E/, 'getCakes request has no phrase');
    }

    my $res = $log->{response};
    ok($res, 'got a logged response');

    if ($req =~ /setCakes/) {
      unlike($res, qr/\Qphrase\E/, 'setCakes response has no phrase');
    } else {
      like($res, qr/\Q"phrase":"***MASKED***"\E/, 'got a masked response');
    }
  }
}

done_testing;
