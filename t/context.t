use 5.20.0;
use warnings;
use utf8;
use experimental qw(lexical_subs signatures postderef refaliasing);

use lib 't/lib';

use Bakesale;
use Bakesale::App;
use Bakesale::Schema;
use Test::More;

my ($app, $jmap_tester) = Bakesale::Test->new_test_app_and_tester;

{
  # No user cookie, should get 410 response
  my $res = $jmap_tester->request([[ getCookies => {} ]])->http_response;
  is($res->code, 410, 'got 410 with no cookie');
  is($res->decoded_content, '{}', 'empty json object');
}

{
  # Bad user cookie, should get 410 response with error. Make sure headers
  # are filled in
  $jmap_tester->_set_cookie('bakesaleUserId', "-5");

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
}

done_testing;
