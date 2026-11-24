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
};

done_testing;
