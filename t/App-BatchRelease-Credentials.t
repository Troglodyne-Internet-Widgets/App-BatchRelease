#!perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use Test::MockModule;
use Mojolicious();
use Mojo::UserAgent();
use Mojo::Util();
use FindBin::libs;

use App::BatchRelease::Credentials();

# A handle that reads the text, as standard input would.
sub input ($text) {
    open( my $fh, '<', \$text ) or die "open: $!";
    return $fh;
}

subtest load => sub {
    my $credentials = App::BatchRelease::Credentials->new->load( input("username: TESTER\npassword:  spaced out \n\nusername: AFTER\n") );
    is( [ $credentials->username, $credentials->password ], [ 'TESTER', ' spaced out ' ], 'each name: value, up to the blank line; the space after the colon goes, and the rest of the value stays' );
    ok( $credentials->from_stdin, 'standard input is spoken for' );

    is( App::BatchRelease::Credentials->new->load( input('password: x') )->password, 'x', 'the end of the input ends the block too' );
    like( dies { App::BatchRelease::Credentials->new->load( input("user: TESTER\n") ) }, qr{\AUnknown\ credential\ 'user'}, 'an unknown name dies, rather than leaving it to a prompt nobody answers' );
    my $error = dies { App::BatchRelease::Credentials->new->load( input("hunter2\n") ) };
    like( $error, qr{Expected\ 'name:\ value'}, 'a line that is not name: value dies' );
    unlike( $error, qr{hunter2}, 'and the message does not repeat the line, which may be a password' );
};

subtest ask => sub {
    my ( @asked, @answers, $interactive );
    my $prompt = Test::MockModule->new('App::BatchRelease::Prompt');
    $prompt->redefine( ask         => sub ( $message, %options ) { push @asked, [ $message, \%options ]; return shift @answers } );
    $prompt->redefine( interactive => sub () { return $interactive } );
    $prompt->redefine( at_terminal => sub ($what) { return ( -in => "tty-in for $what", -out => 'tty-out' ) } );

    ( $interactive, @answers ) = ( 1, 'TESTER', 'secret' );
    my $credentials = App::BatchRelease::Credentials->new->ask;
    is( [ $credentials->username, $credentials->password ], [qw{TESTER secret}],                                 'asks for both' );
    is( [ map { $_->[0] } @asked ],                         [ 'PAUSE username:', 'PAUSE password for TESTER:' ], 'the username first, then the password for it' );
    is( $asked[1][1],                                       { -echo => '*' },                                    'the password is masked' );

    @asked = ();
    ( $interactive, @answers ) = ( 0, 'secret' );
    $credentials = App::BatchRelease::Credentials->new( username => 'TESTER', from_stdin => 1 )->ask;
    is( $credentials->password, 'secret',                                                                       'only what the block did not give' );
    is( $asked[0][1],           { -echo => '*', -in => 'tty-in for the PAUSE credentials', -out => 'tty-out' }, 'at the terminal, because standard input carried the block' );

    @asked = ();
    App::BatchRelease::Credentials->new( username => 'TESTER', password => 'secret' )->ask;
    is( \@asked, [], 'nothing is asked when both are there' );

    $interactive = 0;
    like( dies { App::BatchRelease::Credentials->new->ask }, qr{\ANobody\ can\ type}, 'no terminal and no block: it dies at once, rather than wait' );

    ( $interactive, @answers ) = ( 1, q{} );
    like( dies { App::BatchRelease::Credentials->new->ask }, qr{input\ ended}, 'an input that ends before an answer dies' );
};

subtest typed => sub {
    is( App::BatchRelease::Credentials::typed( 'TESTER', 'the name' ), 'TESTER', 'the answer as a string' );
    like( dies { App::BatchRelease::Credentials::typed( undef,                          'the name' ) }, qr{\ANothing\ was\ typed\ for\ the\ name}, 'no answer' );
    like( dies { App::BatchRelease::Credentials::typed( bless( {}, 'Test::EmptyLine' ), 'the name' ) }, qr{\AAn\ empty\ answer},                   'an empty line, which IO::Prompter gives as a true object' );
};

subtest check_with_pause => sub {
    my $seen;
    my $fake = Mojolicious->new;
    $fake->log->level('fatal');
    $fake->routes->get(
        '/pause/authenquery' => sub ($c) {
            $seen = $c->req->headers->authorization;
            return $c->render( text => 'ok' ) if $seen eq 'Basic ' . Mojo::Util::b64_encode( 'TESTER:right', q{} );
            return $c->render( text => 'gone', status => 503 ) if $seen eq 'Basic ' . Mojo::Util::b64_encode( 'TESTER:down', q{} );
            return $c->render( text => 'no',   status => 401 );
        }
    );
    my $ua     = Mojo::UserAgent->new;
    my $server = $ua->server;
    $server->app($fake);
    my $login = $server->url;
    local $App::BatchRelease::Credentials::PAUSE_LOGIN = $login->path('/pause/authenquery')->to_string;

    is( App::BatchRelease::Credentials->new( username => 'TESTER', password => 'right' )->check_with_pause($ua),          1,                                                        'PAUSE takes them' );
    is( $seen,                                                                                                            'Basic ' . Mojo::Util::b64_encode( 'TESTER:right', q{} ), 'sent as HTTP basic authentication' );
    is( dies { App::BatchRelease::Credentials->new( username => 'TESTER', password => 'wrong' )->check_with_pause($ua) }, "PAUSE refused the username and password.\n",             'a 401 stops the run' );
    like( warning { is( App::BatchRelease::Credentials->new( username => 'TESTER', password => 'down' )->check_with_pause($ua), 0, 'another error does not stop it' ) }, qr{PAUSE\ answered\ 503}, 'and warns' );
};

done_testing;

package Test::EmptyLine;
use overload 'bool' => sub { 1 }, q{""} => sub { q{} };
