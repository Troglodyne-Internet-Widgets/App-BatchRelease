#!perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use Test::MockModule;
use File::Temp();
use FindBin::libs;

use App::BatchRelease::Source::Git();

# Answers git from %ANSWERS: each command line, joined by spaces, gives an
# exit status and an output.  A command that the table lacks fails the test.
# Each command line goes to @ASKED.
my ( %ANSWERS, @ASKED );
my $git = Test::MockModule->new('App::BatchRelease::Source::Git')->redefine(
    git => sub ( $self, @args ) {
        my $line = join q{ }, @args;
        push @ASKED, $line;
        my $answer = $ANSWERS{$line} // die "unexpected git $line\n";
        my ( $status, $out ) = @$answer;
        return ( $status, $out )        if wantarray;
        die "git $line: exit $status\n" if $status;
        return $out;
    }
);

sub fake_git (%answers) {
    %ANSWERS = %answers;
    @ASKED   = ();
    return;
}

my $root = '/bogus/Test-Dist';

subtest default_branch => sub {
    fake_git( 'symbolic-ref --quiet --short refs/remotes/origin/HEAD' => [ 0, "origin/trunk\n" ] );
    my $source = App::BatchRelease::Source::Git->new( root => $root );
    is( $source->default_branch, 'trunk', 'the branch that origin/HEAD points at' );
    is( $source->default_branch, 'trunk', 'asked again' );
    is( scalar @ASKED,           1,       'memoized: git is asked once' );

    fake_git(
        'symbolic-ref --quiet --short refs/remotes/origin/HEAD' => [ 1, q{} ],
        'rev-parse --verify --quiet refs/heads/main'            => [ 1, q{} ],
        'rev-parse --verify --quiet refs/heads/master'          => [ 0, "abc\n" ],
    );
    is( App::BatchRelease::Source::Git->new( root => $root )->default_branch, 'master', 'without origin/HEAD, main or else master, whichever exists' );

    fake_git(
        'symbolic-ref --quiet --short refs/remotes/origin/HEAD' => [ 1, q{} ],
        'rev-parse --verify --quiet refs/heads/main'            => [ 1, q{} ],
        'rev-parse --verify --quiet refs/heads/master'          => [ 1, q{} ],
    );
    is( dies { App::BatchRelease::Source::Git->new( root => $root )->default_branch }, "Cannot tell the default branch of /bogus/Test-Dist: origin/HEAD is not set, and there is no branch main or master\n", 'none of them: it dies rather than guess' );
};

subtest file => sub {
    fake_git(
        'symbolic-ref --quiet --short refs/remotes/origin/HEAD' => [ 0,   "origin/main\n" ],
        'cat-file -p refs/heads/main:dist.ini'                  => [ 0,   "name = Test-Dist\n" ],
        'cat-file -p refs/heads/main:missing'                   => [ 128, q{} ],
    );
    my $source = App::BatchRelease::Source::Git->new( root => $root );
    is( $source->file('dist.ini'), "name = Test-Dist\n", 'the content of the file on the default branch, not in the work tree' );
    is( $source->file('missing'),  undef,                'undef for a file that is not there' );
};

subtest compare => sub {
    fake_git(
        'rev-parse --verify --quiet refs/tags/0.001^{commit}'              => [ 1, q{} ],
        'rev-parse --verify --quiet refs/tags/0.002^{commit}'              => [ 0, "abc\n" ],
        'log --reverse --format=%H%x09%s refs/tags/0.002..refs/heads/main' => [ 0, "aaa\tFirst\nbbb\tSecond\twith a tab\n" ],
        'rev-parse --verify --quiet refs/tags/0.003^{commit}'              => [ 0, "abc\n" ],
        'log --reverse --format=%H%x09%s refs/tags/0.003..refs/heads/main' => [ 0, q{} ],
    );
    my $source = App::BatchRelease::Source::Git->new( root => $root );
    is( $source->compare( '0.001', 'main' ), undef, 'undef for a tag that does not exist, looked up under refs/tags/ so a branch of that name cannot answer' );
    is(
        $source->compare( '0.002', 'main' ),
        { ahead_by => 2, commits => [ { sha => 'aaa', subject => 'First', url => undef }, { sha => 'bbb', subject => "Second\twith a tab", url => undef } ] },
        'each commit after the tag, oldest first, and a subject keeps its own tabs'
    );
    is( $source->compare( '0.003', 'main' ), { ahead_by => 0, commits => [] }, 'nothing after the tag' );
};

subtest 'tags, current_branch and changes' => sub {
    fake_git(
        'for-each-ref --format=%(refname:short) refs/tags' => [ 0, "0.001\nv0.002\n" ],
        'symbolic-ref --quiet --short HEAD'                => [ 0, "main\n" ],
        '--no-optional-locks status --porcelain'           => [ 0, " M lib/Test.pm\n?? new.txt\n" ],
    );
    my $source = App::BatchRelease::Source::Git->new( root => $root );
    is( [ $source->tags ],       [qw{0.001 v0.002}],                 'every tag' );
    is( $source->current_branch, 'main',                             'the branch that is checked out' );
    is( [ $source->changes ],    [ ' M lib/Test.pm', '?? new.txt' ], 'changed and untracked paths, read without taking the index lock' );

    fake_git( 'symbolic-ref --quiet --short HEAD' => [ 1, q{} ], '--no-optional-locks status --porcelain' => [ 0, q{} ] );
    $source = App::BatchRelease::Source::Git->new( root => $root );
    is( $source->current_branch, undef, 'a detached head has no branch' );
    is( [ $source->changes ],    [],    'a clean work tree has no changes' );
};

subtest 'tip, and file and compare at a tip' => sub {
    fake_git(
        'symbolic-ref --quiet --short refs/remotes/origin/HEAD'                     => [ 0, "origin/main\n" ],
        'cat-file -p refs/remotes/origin/main:dist.ini'                             => [ 0, "name = Test-Dist\nversion = 0.003\n" ],
        'rev-parse --verify --quiet refs/tags/0.002^{commit}'                       => [ 0, "abc\n" ],
        'log --reverse --format=%H%x09%s refs/tags/0.002..refs/remotes/origin/main' => [ 0, "aaa\tPulled\n" ],
    );
    my $source = App::BatchRelease::Source::Git->new( root => $root );
    is( $source->tip('main'), 'refs/heads/main', 'without tips, a branch is read at refs/heads/' );
    $source->tips->{main} = 'refs/remotes/origin/main';
    is( $source->tip('main'),                'refs/remotes/origin/main',                                                            'with tips, at the ref they give' );
    is( $source->tip('other'),               'refs/heads/other',                                                                    'and only for the branch they name' );
    is( $source->file('dist.ini'),           "name = Test-Dist\nversion = 0.003\n",                                                 'file reads the default branch at its tip' );
    is( $source->compare( '0.002', 'main' ), { ahead_by => 1, commits => [ { sha => 'aaa', subject => 'Pulled', url => undef } ] }, 'so does compare' );
};

subtest upstream => sub {
    my $format = 'for-each-ref --format=%(upstream)%09%(upstream:short)%09%(upstream:remotename)';
    fake_git(
        "$format refs/heads/main"  => [ 0, "refs/remotes/origin/main\torigin/main\torigin\n" ],
        "$format refs/heads/topic" => [ 0, "refs/heads/main\tmain\t.\n" ],
        "$format refs/heads/alone" => [ 0, "\t\t\n" ],
        "$format refs/heads/gone"  => [ 0, q{} ],
    );
    my $source = App::BatchRelease::Source::Git->new( root => $root );
    is( $source->upstream('main'),  { ref => 'refs/remotes/origin/main', name => 'origin/main', remote => 'origin' }, 'the upstream on a remote, with the remote to fetch' );
    is( $source->upstream('topic'), { ref => 'refs/heads/main', name => 'main', remote => q{.} },                     'an upstream that is a local branch has the remote .' );
    is( $source->upstream('alone'), undef,                                                                            'a branch with no upstream has none' );
    is( $source->upstream('gone'),  undef,                                                                            'nor does a branch that is not there' );
};

subtest divergence => sub {
    my $range  = 'rev-list --left-right --count refs/heads/main...refs/remotes/origin/main';
    my $source = App::BatchRelease::Source::Git->new( root => $root );
    for my $case ( [ "0\t0\n", 0, 0, 'neither' ], [ "0\t1\n", 0, 1, '1 behind' ], [ "3\t0\n", 3, 0, 'ahead' ], [ "1\t2\n", 1, 2, 'ahead and behind' ] ) {
        my ( $out, $ahead, $behind, $what ) = @$case;
        fake_git( $range => [ 0, $out ] );
        is( [ $source->divergence( 'main', 'refs/remotes/origin/main' ) ], [ $ahead, $behind ], "$what: ahead, then behind" );
    }
    fake_git( $range => [ 0, "nonsense\n" ] );
    is( dies { $source->divergence( 'main', 'refs/remotes/origin/main' ) }, "git rev-list in /bogus/Test-Dist gave no counts: nonsense\n", 'output that is not two counts dies rather than count 0' );
};

subtest https_url => sub {
    my %cases = (
        'git@forge.test.test:Owner/Repo.git'            => 'https://forge.test.test/Owner/Repo.git',
        'forge.test.test:Owner/Repo.git'                => 'https://forge.test.test/Owner/Repo.git',
        'git@forge.test.test:/Owner/Repo.git'           => 'https://forge.test.test/Owner/Repo.git',
        'ssh://git@forge.test.test:2222/Owner/Repo.git' => 'https://forge.test.test/Owner/Repo.git',
        'ssh://forge.test.test/Owner/Repo.git'          => 'https://forge.test.test/Owner/Repo.git',
        'https://forge.test.test/Owner/Repo.git'        => undef,
        'http://forge.test.test/Owner/Repo.git'         => undef,
        'file:///bogus/Repo.git'                        => undef,
        '/bogus/Repo.git'                               => undef,
        '../bogus/Repo.git'                             => undef,
        'git@forge.test.test:'                          => undef,
    );
    for my $url ( sort keys %cases ) {
        is( App::BatchRelease::Source::Git::https_url($url), $cases{$url}, "$url gives " . ( $cases{$url} // 'undef' ) );
    }
};

subtest 'fetch, switch and pull' => sub {
    my $ssh   = 'git@forge.test.test:Owner/Repo.git';
    my $https = 'https://forge.test.test/Owner/Repo.git';
    my %url   = ( 'remote get-url origin' => [ 0, "$ssh\n" ] );
    my $fast  = "-c url.$https.insteadOf=$ssh fetch --quiet origin";
    fake_git(
        %url,
        $fast                                => [ 0, q{} ],
        'switch --quiet main'                => [ 0, q{} ],
        'pull --quiet --no-rebase --ff-only' => [ 0, q{} ],
    );
    my $source = App::BatchRelease::Source::Git->new( root => $root );
    $source->fetch('origin');
    $source->switch('main');
    $source->pull;
    is( \@ASKED, [ 'remote get-url origin', $fast, 'switch --quiet main', 'pull --quiet --no-rebase --ff-only' ], 'each runs its git command, a remote over SSH is fetched over HTTPS, and the pull can only fast-forward, whatever pull.rebase says' );

    fake_git( %url, $fast => [ 128, q{} ], 'fetch --quiet origin' => [ 0, q{} ] );
    $source->fetch('origin');
    is( \@ASKED, [ 'remote get-url origin', $fast, 'fetch --quiet origin' ], 'when the fetch over HTTPS fails, it fetches over SSH, as the remote says' );

    fake_git( 'remote get-url origin' => [ 0, "$https\n" ], 'fetch --quiet origin' => [ 0, q{} ] );
    $source->fetch('origin');
    is( \@ASKED, [ 'remote get-url origin', 'fetch --quiet origin' ], 'a remote over HTTPS is fetched once, as it says' );

    fake_git( 'remote get-url .' => [ 2, q{} ], 'fetch --quiet .' => [ 0, q{} ] );
    $source->fetch(q{.});
    is( \@ASKED, [ 'remote get-url .', 'fetch --quiet .' ], 'a remote with no URL, such as . for a local upstream, is fetched as it is' );

    fake_git( 'pull --quiet --no-rebase --ff-only' => [ 128, q{} ], %url, $fast => [ 128, q{} ], 'fetch --quiet origin' => [ 128, q{} ] );
    is( dies { $source->pull },            "git pull --quiet --no-rebase --ff-only: exit 128\n", 'a pull that fails dies' );
    is( dies { $source->fetch('origin') }, "git fetch --quiet origin: exit 128\n",               'so does a fetch that fails over HTTPS and over SSH, with the error of the fetch over SSH' );
};

subtest is_checkout => sub {
    my $dir = File::Temp->newdir;
    fake_git( 'rev-parse --show-toplevel' => [ 0, "$dir\n" ] );
    ok( App::BatchRelease::Source::Git->new( root => "$dir" )->is_checkout, 'the top of a work tree' );
    mkdir "$dir/sub" or die "mkdir: $!";
    ok( !App::BatchRelease::Source::Git->new( root => "$dir/sub" )->is_checkout, 'a directory inside a work tree is not a checkout of its own' );
    fake_git( 'rev-parse --show-toplevel' => [ 128, q{} ] );
    ok( !App::BatchRelease::Source::Git->new( root => "$dir" )->is_checkout, 'no repository at all' );
};

subtest git => sub {
    $git->unmock('git');
    local @App::BatchRelease::Source::Git::GIT = ( $^X, '-e', 'print qq{out:@ARGV}; print STDERR q{trouble}; exit( $ARGV[-1] eq q{fail} ? 3 : 0 )', '--' );
    my $source = App::BatchRelease::Source::Git->new( root => '/bogus/Test-Dist' );
    is( scalar $source->git('ok'),     'out:-C /bogus/Test-Dist ok',                      'runs in the root, and gives the standard output' );
    is( [ $source->git('fail') ],      [ 3, 'out:-C /bogus/Test-Dist fail' ],             'in list context, the exit status and the output, and no death' );
    is( dies { $source->git('fail') }, "git fail in /bogus/Test-Dist: exit 3: trouble\n", 'in scalar context, a failure dies with the status and the standard error' );

    # The fake git fails, and says in its error whether it may prompt.
    local @App::BatchRelease::Source::Git::GIT = ( $^X, '-e', 'print STDERR qq{prompt=$ENV{GIT_TERMINAL_PROMPT}}; exit 1', '--' );
    local $ENV{GIT_TERMINAL_PROMPT} = 1;
    is( dies { $source->fetch('origin') }, "git fetch --quiet origin in /bogus/Test-Dist: exit 1: prompt=0\n",               'fetch runs git with GIT_TERMINAL_PROMPT=0, so it fails rather than ask for a password' );
    is( dies { $source->pull },            "git pull --quiet --no-rebase --ff-only in /bogus/Test-Dist: exit 1: prompt=0\n", 'so does pull' );
    is( $ENV{GIT_TERMINAL_PROMPT},         1,                                                                                'and the environment of the program is as it was' );
};

done_testing;
