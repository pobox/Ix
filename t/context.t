use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use Test::More;
use Ix::Util qw(ix_new_id);

{
  my ($test_env) = Bakesale::Test->new_test_env;
  my ($app, $jmap_tester) = $test_env->@{qw(app tester)};

  {
    # No user cookie, should get 410 response
    my $res = $jmap_tester->request([[ getCookies => {} ]])->http_response;
    is($res->code, 410, 'got 410 with no cookie');
    is($res->decoded_content, '{}', 'empty json object');
  }

  {
    # Bad user cookie, should get 410 response with error. Make sure headers
    # are filled in
    local %ENV;

    my $bad_id = $ENV{BAD_ID} = ix_new_id();
    $jmap_tester->_set_cookie('bakesaleUserId', $bad_id);

    $jmap_tester->ua->default_header('Origin' => 'example.net');

    my $res = $jmap_tester->request([[ getCookies => {} ]])->http_response;
    is($res->code, 410, 'got 410 with bad cookie');
    is($res->decoded_content, '{"error":"bad auth"}', 'got error in body');

    for my $hdr (
      [ 'Vary', 'Origin' ],
      [ 'Access-Control-Allow-Origin', 'example.net' ],
      [ 'Access-Control-Allow-Credentials', 'true' ],
    ) {
      is(
        $res->header($hdr->[0]),
        $hdr->[1],
        "$hdr->[0] is correct"
      );
    }

    ok($res->header('Ix-Transaction-ID'), 'we have a request guid!');
  }
};

done_testing;
