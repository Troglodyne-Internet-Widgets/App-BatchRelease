#!perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use Test::MockModule;
use Capture::Tiny qw{capture};
use Cwd();
use File::Temp();
use Mojo::File();
use Dist::Zilla::Chrome::Term();
use Dist::Zilla::Dist::Builder();
use Dist::Zilla::Plugin::UploadToCPAN();
use FindBin::libs;

use App::BatchRelease::Credentials();
use App::BatchRelease::Release();

# Dist::Zilla reads no ~/.dzil/config.ini under DZIL_TESTING, and the empty
# home has no ~/.pause, so the user's own credentials cannot answer here.
my $home = File::Temp->newdir;
local $ENV{HOME}         = "$home";
local $ENV{DZIL_TESTING} = 1;

my $credentials = App::BatchRelease::Credentials->new( username => 'TESTER', password => 'hunter2' );

# A distribution whose only releaser is [UploadToCPAN], with its stash and
# its config file pointed at nothing, in a directory that the test removes.
sub distribution ( $extra = q{} ) {
    my $dir = File::Temp->newdir;
    Mojo::File->new( $dir, 'dist.ini' )->spew(<<"INI");
name = Test-Dist
version = 0.001
abstract = A distribution for a test
author = A. Tester <tester\@test.test>
license = Perl_5
copyright_holder = A. Tester
[GatherDir]
[UploadToCPAN]
pause_cfg_file = /bogus/.pause
$extra
INI
    my $lib = Mojo::File->new( $dir, 'lib', 'Test' )->make_path;
    $lib->child('Dist.pm')->spew("package Test::Dist;\n1;\n");
    return $dir;
}

subtest 'dzil_release' => sub {
    my %uploaded;

    # Mocked through the symbol table, which these immutable Moose classes allow
    # only when they are mutable again.
    Dist::Zilla::Plugin::UploadToCPAN->meta->make_mutable;
    Dist::Zilla::Chrome::Term->meta->make_mutable;
    my $upload   = Test::MockModule->new('Dist::Zilla::Plugin::UploadToCPAN')->redefine( release => sub ( $self, $archive ) { %uploaded = ( user => $self->username, password => $self->password, archive => "$archive" ); return } );
    my $prompted = 0;
    my $chrome   = Test::MockModule->new('Dist::Zilla::Chrome::Term')->redefine( prompt_str => sub { $prompted++; return 'from a prompt' } );

    my $dir = distribution("credentials_stash = %Bogus\n");
    my $cwd = Cwd::getcwd();
    my $built;
    my $done = eval {
        capture { $built = App::BatchRelease::Release::dzil_release( "$dir", $credentials ) };
        1;
    };
    my $error = $@;
    chdir $cwd                                              or die "chdir $cwd: $!";
    ok( $done, 'the release ran, as dzil release runs it' ) or diag $error;
    is( $built, Mojo::File->new( $dir, 'Test-Dist-0.001' )->realpath->to_string, 'it returns the absolute path of the build' );
    ok( -e "$built/lib/Test/Dist.pm", 'which has the modules that were released' );
    is( [ @uploaded{qw{user password}} ], [qw{TESTER hunter2}], 'the upload got the username and password of this program, whatever stash dist.ini names' );
    like( $uploaded{archive}, qr{Test-Dist-0[.]001[.]tar[.]gz\z}, 'and the archive of the build' );
    is( $prompted, 0, 'nothing was asked' );
};

subtest hand_credentials => sub {
    my $dir   = distribution("[UploadToCPAN / Second]\n");
    my $zilla = Dist::Zilla::Dist::Builder->from_config( { dist_root => "$dir", chrome => Dist::Zilla::Chrome::Term->new } );
    is( App::BatchRelease::Release::hand_credentials( $zilla, $credentials ), 2, 'every [UploadToCPAN] of the distribution' );
    my @uploaders = grep { $_->isa('Dist::Zilla::Plugin::UploadToCPAN') } @{ $zilla->plugins };
    my @given;
    for my $plugin (@uploaders) { push @given, [ $plugin->username, $plugin->password ] }
    is( \@given, [ [qw{TESTER hunter2}], [qw{TESTER hunter2}] ], 'each has both' );
};

subtest release => sub {
    my $outcome;
    my $mock = Test::MockModule->new('App::BatchRelease::Release')->redefine(
        dzil_release => sub ( $root, $given ) {
            die "the build broke\n" if $root eq '/bogus/broken';
            kill 'KILL', $$ if $root eq '/bogus/killed';
            die "the child did not get the credentials\n" if $given->password ne 'hunter2';
            return '/bogus/fine/Test-Dist-0.001';
        }
    );
    my ( $out, $err ) = capture { $outcome = App::BatchRelease::Release::release( '/bogus/fine', $credentials ) };
    is( $outcome, { error => undef, built => '/bogus/fine/Test-Dist-0.001' }, 'a release that succeeds in the child has no error, and the child had the credentials from its parent and told it where it built' );
    ( $out, $err ) = capture { $outcome = App::BatchRelease::Release::release( '/bogus/broken', $credentials ) };
    is( $outcome, { error => 'the release exited 1', built => undef },      'a release that dies says so' );
    is( $err,     "The release of /bogus/broken failed: the build broke\n", 'and the child printed why' );
    ( $out, $err ) = capture { $outcome = App::BatchRelease::Release::release( '/bogus/killed', $credentials ) };
    is( $outcome->{error}, 'the release was killed by signal 9', 'a child killed by a signal names it' );

    my $tty = File::Temp->new;
    print {$tty} "typed\n";
    close $tty or die "close: $!";
    $mock->redefine( dzil_release => sub ( $root, $given ) { die "stdin was not the terminal\n" if <STDIN> ne "typed\n"; return } );
    ( $out, $err ) = capture { $outcome = App::BatchRelease::Release::release( '/bogus/fine', $credentials, stdin => $tty->filename ) };
    is( $outcome, { error => undef, built => undef }, 'with stdin, the child reads its questions from there' ) or diag $err;

    local $ENV{PERL5LIB} = '/bogus/before';
    $mock->redefine( dzil_release => sub ( $root, $given ) { die "PERL5LIB is $ENV{PERL5LIB}\n" if $ENV{PERL5LIB} ne '/bogus/one/lib:/bogus/two/lib:/bogus/before'; return } );
    ( $out, $err ) = capture { $outcome = App::BatchRelease::Release::release( '/bogus/fine', $credentials, lib => [qw{/bogus/one/lib /bogus/two/lib}] ) };
    is( $outcome->{error}, undef,           'with lib, the child puts the directories at the front of PERL5LIB, for the tests of the release' ) or diag $err;
    is( $ENV{PERL5LIB},    '/bogus/before', 'and the parent keeps its own' );
};

done_testing;
