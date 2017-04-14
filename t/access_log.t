use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use JSON::MaybeXS qw(decode_json);
use Test::Deep;
use Test::Deep::JType;
use Test::More;

{
  my ($test_env) = Bakesale::Test->new_test_env;
  my ($app, $jmap_tester) = $test_env->@{qw(app tester)};

  \my %account = Bakesale::Test->load_trivial_account(
    $app->processor->schema_connection
  );

  $jmap_tester->_set_cookie('bakesaleUserId', $account{users}{rjbs});

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

  # Should be ignored, behind_proxy defaults to disabled.
  $jmap_tester->ua->default_header('X-Forwarded-For' => '1.2.3.4');

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

  {
    # Test behind_proxy setting
    my $log_data;

    open(my $log_fh, '>', \$log_data);

    my $app = Bakesale::App->new({
      transaction_log_enabled => 1,
      processor => Bakesale->new({
        behind_proxy => 1,
      }),
    });

    $app->access_log_fh($log_fh);
    $app->access_log_enabled(1);

    LWP::Protocol::PSGI->register($app->to_app, host => 'bakesale.local:65534');

    my $jmap_tester = JMAP::Tester->new({
      api_uri => "http://bakesale.local:65534/jmap",
    });

    $jmap_tester->_set_cookie('bakesaleUserId', $account{users}{rjbs});

    # Our real request ip!
    $jmap_tester->ua->default_header('X-Forwarded-For' => '1.2.3.4');

    my $res = $jmap_tester->request([
      [ pieTypes => { tasty => 1 } ],
    ]);

    jcmp_deeply(
      $res->sentence(0)->as_pair,
      [ pieTypes => { flavors => [ qw(pumpkin apple pecan) ] } ],
      "first call response: as expected",
    );

    my @lines = split(qr/\n/, $log_data);
    is(@lines, 1, 'got one log line');

    my $json = eval { decode_json($lines[0]); }; warn $@ if $@;
    ok($json, 'decoded the data');

    is(
      $json->{remote_ip},
      '1.2.3.4',
      'behind_proxy worked, we got the request ip from X-Forwarded-For'
    );
  }
};

done_testing;
