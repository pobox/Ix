use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use JSON qw(decode_json);
use Test::Deep;
use Test::Deep::JType;
use Test::More;

my ($app, $jmap_tester) = Bakesale::Test->new_test_app_and_tester;
\my %dataset = Bakesale::Test->load_trivial_dataset($app->processor->schema_connection);

$jmap_tester->_set_cookie('bakesaleUserId', $dataset{users}{rjbs});

{
# XXX - Create us some initial cakes. If we don't do this, we get a bizarre
#       failure:
#
# DBIx::Class::Row::update(): Can't update Bakesale::Schema::Result::State=HASH(0x5982e18):
# row not found at lib/Ix/DatasetState.pm line 81
#
# Fix this failure. -- alh, 2016-10-19

  my $res = $jmap_tester->request([
    [
      setCakes => {
        create => {
          yum => { type => 'wedding', layer_count => 4, recipeId => $dataset{recipes}{1} },
          woo => { type => 'wedding', layer_count => 8, recipeId => $dataset{recipes}{1} },
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
              type => 'basic'
            },
            {
              cakeId => $res->as_stripped_struct->[0][1]{created}{woo}{id},
              id => ignore(),
              type => 'basic'
            },
          ),
          notFound => ignore(),
          state => 2,
        }), "my id"
      ],
    ],
    "we can bake wedding cakes and get back toppers",
  ) or diag explain( $jmap_tester->strip_json_types( $res->as_pairs ) );
}

my $log_data;
open(my $log_fh, '>', \$log_data);

$app->access_log_fh($log_fh);
$app->access_log_enabled(1);

my $elapsed_re = re('\d+\.\d+|\d+e-\d+');

my %common = (
  content_encoding => undef,
  content_length   => re('\d+'),
  content_type     => 'application/json',
  elapsed_seconds  => $elapsed_re,
  guid             => re('[A-Z0-9-]+'),
  method           => 'POST',
  referer          => undef,
  remote_host      => 'localhost',
  remote_ip        => '127.0.0.1',
  request_uri      => '/jmap',
  response_code    => 200,
  response_length  => re('\d+'),
  seq              => re('\d+'),
  time             => re('\d\d\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ'),
  user_agent       => re('.+'),
);

my $res = $jmap_tester->request([
  [ pieTypes => { tasty => 1 } ],
  [ pieTypes => { tasty => 0 } ],
]);

jcmp_deeply(
  $res->sentence(0)->as_pair,
  [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] } ],
  "first call response: as expected",
);

# Get us some exceptions
local @ENV{qw(NO_CAKE_TOPPERS QUIET_BAKESALE)} = (1, 1);

print STDERR "Ignore the next two exception reports for now..\n";
$res = $jmap_tester->request([
  [
    setCakes => {
      create => {
        yum => { type => 'wedding', layer_count => 4, recipeId => $dataset{recipes}{1} },
        woo => { type => 'wedding', layer_count => 8, recipeId => $dataset{recipes}{1} },
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

my @lines = split(qr/\n/, $log_data);
is(@lines, 2, 'got two log lines');

for my $line (@lines) {
  my $json = eval { decode_json($line); }; warn $@ if $@;
  ok($json, 'decoded the data');

  cmp_deeply(
    $json,
    {
      %common,
      $line =~ /pieTypes/ ? (
        call_info => [
          [
            pieTypes => { elapsed_seconds => $elapsed_re },
          ],
          [
            pieTypes => { elapsed_seconds => $elapsed_re },
          ],
        ],
      ) : (
        call_info => [
          [
            setCakes => { elapsed_seconds => $elapsed_re },
          ],
        ],
        exception_guids => [ re('[A-Z0-9-]+'), re('[A-Z0-9-]+') ],
      )
    },
    "log line looks right"
  ) or diag explain $json;
}

done_testing;
