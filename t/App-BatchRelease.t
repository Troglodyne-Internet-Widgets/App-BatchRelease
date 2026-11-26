#!perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use Test::MockModule;
use Capture::Tiny qw{capture};
use File::Temp();
use Mojo::File();
use FindBin qw{$Bin};
use FindBin::libs;

use App::BatchRelease();

# Directories that the test removes: one without dist.ini, and checkouts with one.
my $top = File::Temp->newdir;
my %dir;
for my $name (qw{plain Test-Base Test-App Test-Other Test-Copy Test-Late}) {
    $dir{$name} = Mojo::File->new( $top, $name )->make_path;
    $dir{$name}->child('dist.ini')->spew("name = $name\n") if $name ne 'plain';
}

# The state that release_state gives for each checkout, by the last part of its path.
my %STATE = (
    'Test-Base'  => { name => 'Test-Base',  version => '0.002', state => 'not_uploaded', latest => '0.001' },
    'Test-App'   => { name => 'Test-App',   version => '1.000', state => 'never_released' },
    'Test-Other' => { name => 'Test-Other', version => '0.010', state => 'released' },
    'Test-Copy'  => { name => 'Test-Base',  version => '0.002', state => 'not_uploaded', latest => '0.001' },
    'Test-Late'  => { name => 'Test-Late',  version => '0.001', state => 'never_released' },
);

# Fakes git and MetaCPAN for inspect: each checkout is the top of its work
# tree, on main, clean, with the upstream origin/main, neither ahead nor
# behind it, unless %git says otherwise for its path.  Each command that
# writes goes to @WROTE, and the tips of the source that release_state
# sees go to %TIPS.
my ( %git, @WROTE, %TIPS );
my $origin = { ref => 'refs/remotes/origin/main', name => 'origin/main', remote => 'origin' };
my $source = Test::MockModule->new('App::BatchRelease::Source::Git');
$source->redefine( is_checkout    => sub ($self) { return $git{ $self->root }{checkout} // 1 } );
$source->redefine( default_branch => sub ($self) { return 'main' } );
$source->redefine( current_branch => sub ($self) { return exists $git{ $self->root }{branch} ? $git{ $self->root }{branch} : 'main' } );
$source->redefine( changes        => sub ($self) { return @{ $git{ $self->root }{changes} // [] } } );
$source->redefine(
    upstream => sub ( $self, $branch ) {
        die $git{ $self->root }{upstream_error} if defined $git{ $self->root }{upstream_error};
        return exists $git{ $self->root }{upstream} ? $git{ $self->root }{upstream} : $origin;
    }
);
$source->redefine( divergence => sub ( $self, $branch, $ref ) { return @{ $git{ $self->root }{divergence} // [ 0, 0 ] } } );
$source->redefine(
    fetch => sub ( $self, $remote ) {
        push @WROTE, "fetch $remote";
        die $git{ $self->root }{fetch_error} if defined $git{ $self->root }{fetch_error};
        return;
    }
);
$source->redefine(
    switch => sub ( $self, $branch ) {
        push @WROTE, "switch $branch";
        $git{ $self->root }{branch} = $branch;
        return;
    }
);
$source->redefine(
    pull => sub ($self) {
        push @WROTE, 'pull';
        die $git{ $self->root }{pull_error} if defined $git{ $self->root }{pull_error};
        $git{ $self->root }{divergence} = [ 0, 0 ];
        return;
    }
);
my $state = Test::MockModule->new('App::BatchRelease::State');
$state->redefine(
    release_state => sub ( $checkout, $cpan ) {
        my $name = Mojo::File->new( $checkout->root )->basename;
        die "MetaCPAN GET /release/versions/$name: 500 Internal Server Error\n" if $git{ $checkout->root }{broken};
        %TIPS = %{ $checkout->tips };
        return { repo => $checkout->id, %{ $STATE{$name} } };
    }
);

# Fakes the prerequisites: Test-App requires Test::Base, which Test-Base provides.
my $prereqs = Test::MockModule->new('App::BatchRelease::Prereqs');
$prereqs->redefine( provides => sub ($root) { return [ Mojo::File->new($root)->basename =~ s{-}{::}r ] } );

sub app_requires_base () {
    $prereqs->redefine( requires => sub ($root) { return Mojo::File->new($root)->basename eq 'Test-App' ? ['Test::Base'] : [] } );
    return;
}

# The first length $want characters of $got, to compare with $want.
sub start ( $got, $want ) { return substr( $got // q{}, 0, length $want ) }

subtest due => sub {
    is( App::BatchRelease::due( { state => 'never_released' } ),                                                                               undef, 'never released is due' );
    is( App::BatchRelease::due( { state => 'not_uploaded', version => '1', latest => '0' } ),                                                  undef, 'a raised version is due' );
    is( App::BatchRelease::due( { state => 'unreleased_commits', version_from => 'tag', version => '0.003', tag => '0.003', ahead_by => 2 } ), undef, 'commits after the tag are due when the tags give the next version' );
    is(
        App::BatchRelease::due( { state => 'unreleased_commits', version => '0.003', tag => 'v0.003', ahead_by => 1 } ),
        '1 commit after the tag v0.003, but dist.ini still says 0.003, which CPAN has: raise the version to release them',
        'commits after the tag, with the released version still in dist.ini, need a new version first'
    );
    is( App::BatchRelease::due( { state => 'released', version => '0.003' } ), 'released: CPAN has 0.003, and the default branch has nothing after its tag',         'released is not due' );
    is( App::BatchRelease::due( { state => 'no_tag',   version => '0.003' } ), 'CPAN has 0.003, but no tag says which commit, so nothing can tell what is released', 'no tag is not due' );
    is( App::BatchRelease::due( { state => 'no_version' } ), 'its dist.ini sets no version and does not load [Git::NextVersion], so nothing can tell what is released', 'no version is not due' );
};

subtest inspect => sub {
    my $app  = App::BatchRelease->new;
    my $base = "$dir{'Test-Base'}";
    is( $app->inspect('/bogus/nowhere')->{skip}, 'not a directory',                                      'a path that is not a directory' );
    is( $app->inspect("$dir{plain}")->{skip},    'no dist.ini, so it is not a Dist::Zilla distribution', 'a directory without dist.ini' );

    $git{$base} = { checkout => 0 };
    is( $app->inspect($base)->{skip}, 'not the top of a git checkout', 'a dist.ini outside the top of a checkout' );

    $git{$base} = { broken => 1 };
    is( $app->inspect($base)->{skip}, 'the check of its state failed: MetaCPAN GET /release/versions/Test-Base: 500 Internal Server Error', 'a check that fails' );

    $git{$base} = {};
    is( $app->inspect($base),                                              { path => $base, repo => $base, %{ $STATE{'Test-Base'} } }, 'a distribution that is due has no skip' );
    is( start( $app->inspect("$dir{'Test-Other'}")->{skip}, 'released:' ), 'released:',                                                'a released one is skipped with the reason of due' );

    $git{$base} = { branch => 'topic' };
    is( $app->inspect($base)->{skip}, 'the checkout is on topic, not on its default branch main', 'a checkout on another branch' );
    $git{$base} = { branch => undef };
    is( $app->inspect($base)->{skip}, 'the checkout is on a detached head, not on its default branch main', 'a detached head' );
    $git{$base} = { changes => [ ' M dist.ini', '?? junk' ] };
    is( $app->inspect($base)->{skip}, '2 changed or untracked paths in the work tree, which dzil release refuses', 'a dirty work tree' );

    $git{$base} = {};
    my $conformance = Test::MockModule->new('App::BatchRelease')->redefine( conformance_problem => sub ($root) { return 'not in full conformance: GitHooks fails' } );
    is( $app->inspect($base)->{skip}, undef, 'without conformant_only, conformance does not matter' );
    $app->conformant_only(1);
    is( $app->inspect($base)->{skip}, 'not in full conformance: GitHooks fails', 'with it, a distribution that does not conform is skipped' );
};

subtest sync => sub {
    my $base = "$dir{'Test-Base'}";

    # inspect $base with the git state %$given, by an app with %options, and
    # gives the entry; @WROTE and %TIPS then say what it wrote and read.
    my sub look ( $given, %options ) {
        $git{$base} = {%$given};
        ( @WROTE, %TIPS ) = ();
        return App::BatchRelease->new(%options)->inspect($base);
    }

    is( look( {} ),                                               { path => $base, repo => $base, %{ $STATE{'Test-Base'} } }, '0 commits behind its upstream: due as before' );
    is( \@WROTE,                                                  ['fetch origin'],                                           'after a fetch of the remote of the upstream' );
    is( look( { divergence => [ 0, 1 ] } )->{skip},               '1 commit behind origin/main',                              '1 commit behind its upstream: skipped, so dzil release cannot upload an old tree' );
    is( look( { divergence => [ 0, 2 ] } )->{skip},               '2 commits behind origin/main',                             'the count of commits behind' );
    is( look( { divergence => [ 3, 0 ] } )->{skip},               undef,                                                      'ahead of its upstream: still due, because [Git::Push] pushes it' );
    is( look( { divergence => [ 0, 1 ] }, dry_run => 1 )->{skip}, '1 commit behind origin/main',                              'a dry run fetches and skips too, without --pull-latest' );
    is( \@WROTE,                                                  ['fetch origin'],                                           'a dry run fetches' );

    is( look( { upstream => undef } )->{skip}, 'its default branch main has no upstream, so nothing can tell whether it is behind; git branch --set-upstream-to gives it one', 'no upstream: skipped, with how to give it one' );
    is( \@WROTE,                               [],                                                                                                                             'and nothing to fetch' );
    is(
        look( { fetch_error => "git fetch --quiet origin in /bogus: exit 128: fatal: unable to access the remote\nmore\n" } )->{skip},
        'git fetch origin failed, so nothing can tell whether main is behind origin/main: git fetch --quiet origin in /bogus: exit 128: fatal: unable to access the remote',
        'a failed fetch: skipped, with the first line of the error'
    );
    is( look( { upstream_error => "git for-each-ref in /bogus: exit 128: fatal: bad object\n" } )->{skip}, 'the check of its default branch against its upstream failed: git for-each-ref in /bogus: exit 128: fatal: bad object', 'a check that dies: skipped, with why' );

    my %pull = ( pull_latest => 1 );
    is( look( { divergence => [ 0, 2 ], branch => 'topic' }, %pull ),       { path => $base, repo => $base, %{ $STATE{'Test-Base'} } }, '--pull-latest: on another branch and behind, it is brought up to date, and due' );
    is( \@WROTE,                                                            [ 'fetch origin', 'switch main', 'pull' ],                  'by a checkout of the default branch, then a pull' );
    is( look( { divergence => [ 0, 1 ], branch => undef }, %pull )->{skip}, undef,                                                      'a detached head is checked out too' );
    is( \@WROTE,                                                            [ 'fetch origin', 'switch main', 'pull' ],                  'and pulled' );
    is( look( { divergence => [ 2, 0 ] }, %pull )->{skip},                  undef,                                                      'on the default branch and ahead: due' );
    is( \@WROTE,                                                            ['fetch origin'],                                           'with nothing to check out or pull' );

    is( look( { divergence => [ 0, 1 ], changes => ['?? junk'] }, %pull )->{skip},             '1 changed or untracked path in the work tree, so --pull-latest cannot fast-forward 1 commit', 'a dirty work tree that would be pulled: skipped' );
    is( \@WROTE,                                                                               ['fetch origin'],                                                                              'and not pulled' );
    is( look( { branch => 'topic', changes => [ ' M dist.ini', '?? junk' ] }, %pull )->{skip}, '2 changed or untracked paths in the work tree, so --pull-latest cannot check out main',       'a dirty work tree that would change branch: skipped' );
    is( \@WROTE,                                                                               ['fetch origin'],                                                                              'and not checked out' );
    is( look( { changes => ['?? junk'] }, %pull )->{skip},                                     '1 changed or untracked path in the work tree, which dzil release refuses',                    'a dirty work tree with nothing to pull is skipped as before' );

    is( look( { divergence => [ 1, 2 ] }, %pull )->{skip},                                                                                                 '2 commits behind origin/main and 1 commit ahead of it, so it cannot fast-forward',                                            'behind and ahead at once: skipped, because it cannot fast-forward' );
    is( \@WROTE,                                                                                                                                           ['fetch origin'],                                                                                                              'and not pulled' );
    is( look( { divergence => [ 0, 1 ], pull_error => "git pull in /bogus: exit 128: fatal: Not possible to fast-forward, aborting.\n" }, %pull )->{skip}, '--pull-latest could not fast-forward 1 commit: git pull in /bogus: exit 128: fatal: Not possible to fast-forward, aborting.', 'a pull that git refuses: skipped, with why' );

    my $entry = look( { divergence => [ 0, 2 ], branch => 'topic' }, %pull, dry_run => 1 );
    is( [ @{$entry}{qw{skip pull}} ], [ undef, 'check out main and fast-forward 2 commits' ], '--dry-run --pull-latest: says what the pull would do, and the branch it is on does not skip it' );
    is( \@WROTE,                      ['fetch origin'],                                       'and does nothing but fetch' );
    is( \%TIPS,                       { main => 'refs/remotes/origin/main' },                 'and gives the state that the fast-forward would give, from the upstream' );
    $entry = look( { branch => 'topic' }, %pull, dry_run => 1 );
    is( [ $entry->{pull}, \%TIPS ], [ 'check out main', {} ], 'only a checkout to do: the state of the default branch as it is' );
    $git{$base} = {};
};

subtest conformance_problem => sub {
    my $results;
    my $mock = Test::MockModule->new('Dist::Conformance')->redefine(
        check => sub ($self) {
            die "The repository has no .conformance.yml, so it names no flavor\n" if !$results;
            return $results;
        }
    );
    is( App::BatchRelease::conformance_problem('/bogus/Test-Dist'), 'the conformance check could not run: The repository has no .conformance.yml, so it names no flavor', 'a check that cannot run is a problem, with its reason' );
    $results = [ { check => 'Distribution', status => 'pass' }, { check => 'Workflows', status => 'info' }, { check => 'Changes', status => 'skip' } ];
    is( App::BatchRelease::conformance_problem('/bogus/Test-Dist'), undef, 'pass, info and skip are full conformance, as conformance check exits 0 for them' );
    push @$results, { check => 'GitHooks', status => 'fail' }, { check => 'CriticProfile', status => 'fail' };
    is( App::BatchRelease::conformance_problem('/bogus/Test-Dist'), 'not in full conformance: GitHooks, CriticProfile fail', 'each check that fails is named' );
};

subtest plan => sub {
    app_requires_base();
    my $plan    = App::BatchRelease->new->plan( map { "$dir{$_}" } qw{Test-App plain Test-Base Test-Other Test-Copy} );
    my @release = @{ $plan->{release} };
    is( [ map { $_->{name} } @release ], [qw{Test-Base Test-App}], 'the one that is required comes first, whatever the order of the paths' );
    is( $release[1]{needs},              ['Test-Base'],            'with what each requires of the batch' );
    is(
        [ map { $_->{skip} } @{ $plan->{skipped} } ],
        [ 'no dist.ini, so it is not a Dist::Zilla distribution', 'released: CPAN has 0.010, and the default branch has nothing after its tag', "$dir{'Test-Base'} is a checkout of the same distribution, and comes first" ],
        'the skipped ones, in the order of the paths, with a second checkout of one distribution among them'
    );

    # Test-App and Test-Base require each other, and Test-Late requires
    # Test-App.
    $prereqs->redefine( requires => sub ($root) { return Mojo::File->new($root)->basename eq 'Test-App' ? ['Test::Base'] : ['Test::App'] } );
    $plan = App::BatchRelease->new->plan( map { "$dir{$_}" } qw{Test-App Test-Base Test-Late} );
    is( $plan->{release}, [], 'two that require each other cannot be ordered, nor one that requires them' );
    is(
        [ map { $_->{skip} } @{ $plan->{skipped} } ],
        [
            ( map { "its requirements form a cycle with $_ of this batch, so no order puts each after the ones it requires" } qw{Test-Base Test-App} ),
            'requires Test-App of this batch, which cannot be released, because of a cycle of requirements'
        ],
        'so all three are skipped, the two of the cycle naming each other, and the third naming what holds it back'
    );

    $prereqs->redefine( requires => sub ($root) { die "Cannot read the prerequisites of $root/lib/X.pm: PPI parse failed\n" if Mojo::File->new($root)->basename eq 'Test-Base'; return ['Test::Base'] } );
    $plan = App::BatchRelease->new->plan( map { "$dir{$_}" } qw{Test-App Test-Base} );
    is( [ map { $_->{name} } @{ $plan->{release} } ], ['Test-App'],                                                                                                          'a distribution whose requirements cannot be read leaves the batch, and the others still go' );
    is( [ map { $_->{skip} } @{ $plan->{skipped} } ], ["its requirements could not be read: Cannot read the prerequisites of $dir{'Test-Base'}/lib/X.pm: PPI parse failed"], 'with the reason' );
};

subtest release_all => sub {
    my ( @released, %lib, %fails );
    my $mock = Test::MockModule->new('App::BatchRelease::Release')->redefine(
        release => sub ( $root, $credentials, %options ) {
            my $name = Mojo::File->new($root)->basename;
            push @released, $name;
            $lib{$name} = $options{lib};
            return { error => $fails{$name}, built => "/bogus/build/$name" };
        }
    );
    my $plan = {
        release => [
            { name => 'Test-Base',  path => "$dir{'Test-Base'}",  needs => [] },
            { name => 'Test-App',   path => "$dir{'Test-App'}",   needs => ['Test-Base'] },
            { name => 'Test-Top',   path => '/bogus/Test-Top',    needs => ['Test-App'] },
            { name => 'Test-Other', path => "$dir{'Test-Other'}", needs => [] },
        ],
        skipped => [ { path => "$dir{plain}", skip => 'no dist.ini, so it is not a Dist::Zilla distribution' } ],
    };

    capture { App::BatchRelease->new->release_all($plan) };
    is( \@released, [qw{Test-Base Test-App Test-Top Test-Other}], 'all go when none fails' );
    is(
        \%lib,
        { 'Test-Base' => undef, 'Test-App' => ['/bogus/build/Test-Base/lib'], 'Test-Top' => [ '/bogus/build/Test-App/lib', '/bogus/build/Test-Base/lib' ], 'Test-Other' => undef },
        'each gets the lib of the build of what it requires of the batch, directly or not, so its tests find modules not yet installed'
    );

    @released = ();
    $fails{'Test-Base'} = 'the release exited 1';
    my ( $out, undef, $outcome ) = capture { App::BatchRelease->new->release_all($plan) };
    is( \@released,                                                    [qw{Test-Base Test-Other}],                  'a failed release stops the ones that require it, directly or not, and the rest go on' );
    is( [ map { $_->{name} } @{ $outcome->{released} } ],              ['Test-Other'],                              'released' );
    is( [ map { [ @{$_}{qw{name error}} ] } @{ $outcome->{failed} } ], [ [ 'Test-Base', 'the release exited 1' ] ], 'failed, with the error' );
    is(
        [ map { $_->{skip} } @{ $outcome->{skipped} } ],
        [ 'no dist.ini, so it is not a Dist::Zilla distribution', 'requires Test-Base, which failed', 'requires Test-App, which was skipped' ],
        'skipped: those of the plan, then those that this run held back, each with why'
    );
    is( start( $out, "\n== Releasing Test-Base from" ), "\n== Releasing Test-Base from", 'each release is announced before its output' );

    my %options;
    $mock->redefine( release => sub ( $root, $credentials, %given ) { %options = %given; return { error => undef, built => undef } } );
    my $app = App::BatchRelease->new;
    $app->credentials->from_stdin(1);
    my $tty = File::Temp->new;
    local $App::BatchRelease::Prompt::TERMINAL = $tty->filename;
    capture { $app->release_all( { release => [ { name => 'Test-Base', path => '/bogus/Test-Base', needs => [] } ], skipped => [] } ) };
    is( \%options, { stdin => $tty->filename }, 'when the credentials came on standard input, each release reads its questions from the terminal' );
};

subtest confirm => sub {
    my ( @asked, $answer, $interactive );
    my $prompt = Test::MockModule->new('App::BatchRelease::Prompt');
    $prompt->redefine( ask         => sub ( $message, %options ) { push @asked, [ $message, \%options ]; return $answer } );
    $prompt->redefine( interactive => sub () { return $interactive } );
    $prompt->redefine( at_terminal => sub ($what) { return ( -in => 'tty', -out => 'tty' ) } );
    my $plan = { release => [ {}, {} ] };

    ( $interactive, $answer ) = ( 1, ' Yes ' );
    ok( App::BatchRelease->new->confirm($plan), 'yes, in any case and with spaces, confirms' );
    is( $asked[0], [ 'Release these 2 distributions to CPAN? [y/N]', {} ], 'the question counts them' );
    $answer = q{};
    ok( !App::BatchRelease->new->confirm($plan), 'an empty answer does not' );
    $answer = 'yep';
    ok( !App::BatchRelease->new->confirm($plan), 'nor anything else' );

    $interactive = 0;
    is( dies { App::BatchRelease->new->confirm($plan) }, "Nobody can confirm the release: standard input is not a terminal.\nPass --yes to release without asking.\n", 'nobody to ask: it dies and says how to go on' );
    @asked = ();
    my $app = App::BatchRelease->new;
    $app->credentials->from_stdin(1);
    $answer = 'y';
    ok( $app->confirm($plan), 'with the credentials on standard input' );
    is( $asked[0][1], { -in => 'tty', -out => 'tty' }, 'it asks at the terminal' );
};

subtest run => sub {
    app_requires_base();
    my ( @released, @calls );
    my $release     = Test::MockModule->new('App::BatchRelease::Release')->redefine( release => sub ( $root, $credentials, %options ) { push @released, [ Mojo::File->new($root)->basename, $credentials->password ]; return { error => undef, built => undef } } );
    my $credentials = Test::MockModule->new('App::BatchRelease::Credentials');
    $credentials->redefine( load             => sub ( $self, $fh = undef ) { push @calls, 'load';  return $self->from_stdin(1) } );
    $credentials->redefine( ask              => sub ($self) { push @calls, 'ask';                  return $self->username('TESTER')->password('hunter2') } );
    $credentials->redefine( check_with_pause => sub ( $self, $ua = undef ) { push @calls, 'check'; return 1 } );
    my $confirmed = 1;
    my $app       = Test::MockModule->new('App::BatchRelease')->redefine( confirm => sub ( $self, $plan ) { push @calls, 'confirm'; return $confirmed } );
    my @paths     = map { "$dir{$_}" } qw{Test-App Test-Base Test-Other};
    my $list      = <<"LIST";
in this order:
  1. Test-Base 0.002: not uploaded, CPAN has 0.001
       $dir{'Test-Base'}
  2. Test-App 1.000: never released; after Test-Base
       $dir{'Test-App'}
Skipped:
  Test-Other ($dir{'Test-Other'}): released: CPAN has 0.010, and the default branch has nothing after its tag
LIST

    my ( $out, $err, $status ) = capture { App::BatchRelease->new->run( '--dry-run', '--credentials', @paths ) };
    is( [ $status, $out ], [ 0, "Would release, $list" ], 'a dry run lists what it would release, in order, with the state and the requirements of each, and what it would skip, with why, and exits 0' );
    is( [ \@released, \@calls ], [ [], [] ], 'and releases nothing, reads no credentials and asks nothing, even with --credentials' );

    ( $out, $err, $status ) = capture { App::BatchRelease->new->run( '--credentials', @paths ) };
    is( $status,    0,                                                         'a run where all went well exits 0' );
    is( \@calls,    [qw{load confirm ask check}],                              'the credentials block is read first, then the list is confirmed, then the credentials are asked for and checked, all before the first release' );
    is( \@released, [ [ 'Test-Base', 'hunter2' ], [ 'Test-App', 'hunter2' ] ], 'each release, in order, with the same credentials' );
    my $summary = <<"SUMMARY";

Summary
Released (2):
  Test-Base 0.002
  Test-App 1.000
Skipped (1):
  Test-Other ($dir{'Test-Other'}): released: CPAN has 0.010, and the default branch has nothing after its tag
Failed (0):
SUMMARY
    is( $out, "To release, $list\n== Releasing Test-Base from $dir{'Test-Base'}\n\n== Releasing Test-App from $dir{'Test-App'}\n$summary", 'the list, each release, then the summary' );

    ( @calls, @released ) = ();
    $confirmed = 0;
    ( $out, $err, $status ) = capture { App::BatchRelease->new->run(@paths) };
    is( [ $status, \@calls, \@released ], [ 0, ['confirm'], [] ],                       'not confirmed: nothing is asked or released' );
    is( $out,                             "To release, ${list}Nothing was released.\n", 'and it says so' );

    @calls = ();
    $release->redefine( release => sub ( $root, $credentials, %options ) { return { error => 'the release exited 1', built => undef } } );
    ( $out, $err, $status ) = capture { App::BatchRelease->new->run( '--yes', '--skip-login-check', @paths ) };
    is( [ $status, \@calls ], [ 1, ['ask'] ], 'with --yes nothing is confirmed, with --skip-login-check nothing is checked, and a failure exits 1' );

    ( $out, $err, $status ) = capture { App::BatchRelease->new->run("$dir{'Test-Other'}") };
    is( start( $out, "Nothing to release.\n" ), "Nothing to release.\n", 'nothing due: it says so' );

    @WROTE                     = ();
    $git{"$dir{'Test-Base'}"}  = { divergence => [ 0, 2 ] };
    $git{"$dir{'Test-Other'}"} = { branch     => 'topic' };
    ( $out, $err, $status ) = capture { App::BatchRelease->new->run( '--dry-run', '--pull-latest', @paths ) };
    is(
        [ $status, $out ],
        [
            0, <<"LIST"
Would release, in this order:
  1. Test-Base 0.002: not uploaded, CPAN has 0.001; would fast-forward 2 commits first
       $dir{'Test-Base'}
  2. Test-App 1.000: never released; after Test-Base
       $dir{'Test-App'}
Skipped:
  Test-Other ($dir{'Test-Other'}): released: CPAN has 0.010, and the default branch has nothing after its tag; would check out main first
LIST
        ],
        '--dry-run --pull-latest says what each pull would do, of those to release and of those to skip'
    );
    is( \@WROTE, [ ('fetch origin') x 3 ], 'and only fetches' );
    $git{$_} = {} for "$dir{'Test-Base'}", "$dir{'Test-Other'}";

    $credentials->redefine( ask => sub ($self) { die "Nobody can type the PAUSE credentials.\n" } );
    my $warned = warning {
        ( $out, $err, $status ) = capture { App::BatchRelease->new->run( '--yes', @paths ) }
    };
    is( [ $status, $warned ], [ 2, "Nobody can type the PAUSE credentials.\n" ], 'a run that cannot get the credentials stops with 2, before any release, and warns why' );

    # The usage comes from the POD of the program, which is $0 when it runs.
    local $0 = Mojo::File->new( $Bin, q{..}, qw{script batch-release} )->to_string;
    ( $out, $err, $status ) = capture { App::BatchRelease->new->run() };
    is( [ $status, start( $err, "Name at least one checkout.\n\nUsage:" ) ], [ 2, "Name at least one checkout.\n\nUsage:" ], 'no checkout is a mistake in the arguments, which it explains, with the usage' );
    like(
        warning {
            ( $out, $err, $status ) = capture { App::BatchRelease->new->run('--bogus') }
        },
        qr{Unknown\ option:\ bogus},
        'an unknown option is named'
    );
    is( $status, 2, 'and is a mistake in the arguments too' );
    ( $out, $err, $status ) = capture { App::BatchRelease->new->run('--help') };
    is( $status, 0, '--help exits 0' );
    like( $out, qr{--conformant-only}, 'and prints the options' );
};

done_testing;
