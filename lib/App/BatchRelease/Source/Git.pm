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
machine.  It runs the git program in the checkout, and only commands that
read: it changes no file, ref or configuration.  C<git status> runs with
C<--no-optional-locks>, so it does not even refresh the index.

Every command runs through L</git>, with a timeout, so a test can replace that
one method.

=attr root

The directory of the checkout.  Required.

=attr id

The name that the result of L<App::BatchRelease::State/release_state>
carries as C<repo>.  Default L</root>.

=attr timeout

Seconds for each git command.  Default 60.

=cut

has root    => sub { die "App::BatchRelease::Source::Git needs a root\n" };
has id      => sub ($self) { $self->root };
has timeout => 60;

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

=method file

C<($path)>.  The content of the file at C<$path> on the default branch, or
undef when it is not there.  It reads the commit of the branch, not the work
tree, as a forge would.

=cut

sub file ( $self, $path ) {
    my $branch = $self->default_branch;
    my ( $status, $content ) = $self->git( 'cat-file', '-p', "refs/heads/$branch:$path" );
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

C<($tag, $branch)>.  As L<App::BatchRelease::State/compare>: undef when the tag
does not exist, else C<ahead_by> and every one of C<commits>, each with an
undef C<url>.

=cut

sub compare ( $self, $tag, $branch ) {
    return if ( $self->git( qw{rev-parse --verify --quiet}, "refs/tags/$tag^{commit}" ) )[0];
    my $log     = $self->git( qw{log --reverse --format=%H%x09%s}, "refs/tags/$tag..refs/heads/$branch" );
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

1;
