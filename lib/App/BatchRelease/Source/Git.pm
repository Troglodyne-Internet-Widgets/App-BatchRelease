package App::BatchRelease::Source::Git;

# ABSTRACT: A local git checkout, as App::BatchRelease::State reads it

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use IPC::Run   ();
use Mojo::File ();

=head1 SYNOPSIS

    use 5.040;
    use App::BatchRelease::Source::Git;

    my $source = App::BatchRelease::Source::Git->new( root => '/bogus/Foo-Bar' );
    my $branch = $source->default_branch;
    my $ahead  = $source->compare( '0.002', $branch );

=head1 DESCRIPTION

The source of L<App::BatchRelease::State/THE SOURCE> for a checkout on this
machine.  It runs the git program in the checkout, which must be git 2.23
or later, for C<git switch>.

Three methods write, and the rest only read: they change no file, ref or
configuration.  C<git status> runs with C<--no-optional-locks>, so it does
not even refresh the index.  The three that write are these:

=over

=item *

L</fetch> changes the refs of a remote and the tags, and no local branch or
work tree.

=item *

L</switch> and L</pull> change the branch that is checked out and the work
tree.  L<App::BatchRelease> calls them only with C<--pull-latest>, and never
on a dry run.

=back

None of them stashes, merges, rebases or resets.  The two that talk to a
remote run with C<GIT_TERMINAL_PROMPT=0>, so that git fails, rather than asks
for a password at the terminal.

Every command runs through L</git>, with a timeout, so a test can replace that
one method.

=attr root

The directory of the checkout.  Required.

=attr id

The name that the result of L<App::BatchRelease::State/release_state>
carries as C<repo>.  Default L</root>.

=attr timeout

Seconds for each git command.  Default 60.

=attr tips

A hash reference from the name of a branch to the ref that L</file> and
L</compare> read for that branch, in place of C<refs/heads/$branch>.  Default
empty.  A dry run with C<--pull-latest> points the default branch at its
upstream, so that the state is the one that the fast-forward would give.

=cut

has root    => sub { die "App::BatchRelease::Source::Git needs a root\n" };
has id      => sub ($self) { $self->root };
has timeout => 60;
has tips    => sub { {} };

# The git program.  A test can point it elsewhere.
our @GIT = ('git');

=method git

C<(@args)>.  Runs git with C<@args> in L</root>.  In list context, the exit
status and the standard output; in scalar context, the standard output, and
it dies with the standard error when git exits with a status other than 0.
Standard input is empty.

=cut

sub git ( $self, @args ) {
    my ( $out, $err ) = ( q{}, q{} );
    my $root = $self->root;
    my $ok   = eval { IPC::Run::run( [ @GIT, '-C', $root, @args ], '<', \undef, '>', \$out, '2>', \$err, IPC::Run::timeout( $self->timeout ) ) };
    die "git @args in $root: $@" if !defined $ok && $@;
    my $status = $? >> 8;
    return ( $status, $out ) if wantarray;
    chomp $err;
    die "git @args in $root: exit $status: $err\n" if $status;
    return $out;
}

=method is_checkout

True when L</root> is the top of the work tree of a git repository, and not
a directory inside one or no repository at all.

=cut

sub is_checkout ($self) {
    my ( $status, $top ) = $self->git(qw{rev-parse --show-toplevel});
    return 0 if $status;
    chomp $top;
    return Mojo::File->new($top)->realpath eq Mojo::File->new( $self->root )->realpath ? 1 : 0;
}

=method tip

C<($branch)>.  The ref that stands for the branch C<$branch>: the one that
L</tips> gives, else C<refs/heads/$branch>.

=cut

sub tip ( $self, $branch ) {
    return $self->tips->{$branch} // "refs/heads/$branch";
}

=method file

C<($path)>.  The content of the file at C<$path> on the default branch, or
undef when it is not there.  It reads the commit at the L</tip> of the
branch, not the work tree, as a forge would.

=cut

sub file ( $self, $path ) {
    my $tip = $self->tip( $self->default_branch );
    my ( $status, $content ) = $self->git( 'cat-file', '-p', "$tip:$path" );
    return if $status;
    return $content;
}

=method default_branch

The name of the default branch: the branch that F<refs/remotes/origin/HEAD>
points at, the one that C<git clone> sets.  Without it, C<main> or else
C<master>, if a local branch has that name.  It dies when none of these is
there.  Memoized for the object.

=cut

sub default_branch ($self) {
    return $self->{default_branch} //= do {
        my ( $status, $remote ) = $self->git(qw{symbolic-ref --quiet --short refs/remotes/origin/HEAD});
        chomp $remote;
        my $prefix = q{origin/};
        my $branch = !$status && index( $remote, $prefix ) == 0 ? substr( $remote, length $prefix ) : undef;
        for my $guess (qw{main master}) {
            last             if defined $branch;
            $branch = $guess if !( $self->git( qw{rev-parse --verify --quiet}, "refs/heads/$guess" ) )[0];
        }
        $branch // die "Cannot tell the default branch of ${\ $self->root }: origin/HEAD is not set, and there is no branch main or master\n";
    };
}

=method compare

C<($tag, $branch)>.  As C<compare> in L<App::BatchRelease::State/THE SOURCE>: undef when the tag
does not exist, else C<ahead_by> and every one of C<commits>, each with an
undef C<url>.  The branch is read at its L</tip>.

=cut

sub compare ( $self, $tag, $branch ) {
    return if ( $self->git( qw{rev-parse --verify --quiet}, "refs/tags/$tag^{commit}" ) )[0];
    my $log     = $self->git( qw{log --reverse --format=%H%x09%s}, "refs/tags/$tag.." . $self->tip($branch) );
    my @commits = map { my ( $sha, $subject ) = split m{\t}, $_, 2; { sha => $sha, subject => $subject // q{}, url => undef } } split m{\n}, $log;
    return { ahead_by => scalar @commits, commits => \@commits };
}

=method tags

The name of every tag.

=cut

sub tags ($self) {
    return split m{\n}, $self->git(qw{for-each-ref --format=%(refname:short) refs/tags});
}

=method current_branch

The branch that is checked out, or undef when the head is detached.

=cut

sub current_branch ($self) {
    my ( $status, $branch ) = $self->git(qw{symbolic-ref --quiet --short HEAD});
    return if $status;
    chomp $branch;
    return $branch;
}

=method changes

Each path that C<git status> reports as changed or untracked, as it reports
it.  None for a clean work tree.

=cut

sub changes ($self) {
    return split m{\n}, $self->git(qw{--no-optional-locks status --porcelain});
}

=method upstream

C<($branch)>.  The upstream of the local branch C<$branch>, as a hash
reference of C<ref>, its full name, such as C<refs/remotes/origin/main>,
C<name>, its short name, such as C<origin/main>, and C<remote>, the remote
that L</fetch> fetches for it, which is C<.> for an upstream that is a local
branch.  Undef when the branch has no upstream.

=cut

sub upstream ( $self, $branch ) {
    my $line = $self->git( 'for-each-ref', '--format=%(upstream)%09%(upstream:short)%09%(upstream:remotename)', "refs/heads/$branch" );
    chomp $line;
    my ( $ref, $name, $remote ) = split m{\t}, $line, 3;
    return if ( $ref // q{} ) eq q{};
    return { ref => $ref, name => $name, remote => $remote };
}

=method divergence

C<($branch, $ref)>.  Two counts: the commits of the local branch C<$branch>
that C<$ref> does not have, which is how far the branch is ahead of it, and
the commits of C<$ref> that the branch does not have, which is how far it is
behind.

=cut

sub divergence ( $self, $branch, $ref ) {
    my $counts = $self->git( qw{rev-list --left-right --count}, "refs/heads/$branch...$ref" );
    chomp $counts;
    my ( $ahead, $behind ) = $counts =~ m{\A(\d+)\t(\d+)\z} or die "git rev-list in ${\ $self->root } gave no counts: $counts\n";
    return ( $ahead, $behind );
}

=method fetch

C<($remote)>.  Writes.  Fetches the remote C<$remote>, as C<git fetch> does.
It changes the refs of the remote and the tags, and no local branch or work
tree.  It dies with the standard error of git when git fails.

=cut

sub fetch ( $self, $remote ) {
    local $ENV{GIT_TERMINAL_PROMPT} = 0;
    $self->git( qw{fetch --quiet}, $remote );
    return;
}

=method switch

C<($branch)>.  Writes.  Checks out the local branch C<$branch>.  Git refuses
when that would overwrite a change in the work tree, and then this dies with
its standard error.

=cut

sub switch ( $self, $branch ) {
    $self->git( qw{switch --quiet}, $branch );
    return;
}

=method pull

Writes.  Brings the branch that is checked out up to its upstream with
C<git pull --ff-only>: a fast-forward, or nothing.  It passes C<--no-rebase>
too, so that a C<pull.rebase> in the configuration cannot make it rebase.  It
dies with the standard error of git when git fails, as when the branch cannot
fast-forward.

=cut

sub pull ($self) {
    local $ENV{GIT_TERMINAL_PROMPT} = 0;
    $self->git(qw{pull --quiet --no-rebase --ff-only});
    return;
}

1;
