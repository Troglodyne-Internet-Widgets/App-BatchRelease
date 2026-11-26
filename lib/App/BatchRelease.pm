package App::BatchRelease;

# ABSTRACT: Release, in one run, every Dist::Zilla distribution of a set of checkouts whose work is not all on CPAN

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use Getopt::Long();
use List::Util();
use Pod::Usage();

use Dist::Conformance();

use App::BatchRelease::Credentials();
use App::BatchRelease::MetaCPAN();
use App::BatchRelease::Prereqs();
use App::BatchRelease::Prompt();
use App::BatchRelease::Release();
use App::BatchRelease::Source::Git();
use App::BatchRelease::State();

=head1 SYNOPSIS

    use 5.040;
    use App::BatchRelease;

    exit App::BatchRelease->new->run( '--dry-run', '/bogus/Foo-Bar', '/bogus/Foo-Baz' );

=head1 DESCRIPTION

This is the program C<batch-release>.  Its POD says how a person uses it.
This page says what each part does, for a caller and for a test.

A run has four steps:

=over

=item 1. L</plan>

Fetches each checkout and looks at it, and sorts them into the ones to
release, in order, and the ones to skip, each with its reason.  It changes no
work tree, unless L</pull_latest> is set and this is not a dry run.

=item 2. L</listing>

Prints both lists.  A dry run stops here.

=item 3. L</confirm>, then the credentials

Asks the person to confirm the list, then asks for the PAUSE username and
password, once, through L<App::BatchRelease::Credentials>.  Both happen
before the first build.

=item 4. L</release_all>

Releases each distribution of the list, in order, through
L<App::BatchRelease::Release>, skips each one that requires a distribution
whose release failed, and prints the summary.

=back

=attr cpan

The client of MetaCPAN.  Default an L<App::BatchRelease::MetaCPAN>.

=attr credentials

The L<App::BatchRelease::Credentials>.

=attr dry_run

True to stop after the list.  Then nothing reads standard input, nothing
asks for credentials, and L</pull_latest> changes no checkout.  The fetch of
L</sync> still runs.

=attr conformant_only

True to skip each distribution that is not in full conformance, as
L</conformance_problem> says.

=attr yes

True to release without asking for confirmation.

=attr check_login

True, the default, to check the credentials with PAUSE before the first
build.  See L<App::BatchRelease::Credentials/check_with_pause>.

=attr pull_latest

True to bring each checkout up to its upstream before the other checks: to
check out the default branch, and to fast-forward it with C<git pull
--ff-only>, as L</sync> says.  On a dry run, it only says what it would do.
Default false, and then a checkout whose default branch is behind its
upstream is skipped.

=cut

has cpan            => sub { App::BatchRelease::MetaCPAN->new };
has credentials     => sub { App::BatchRelease::Credentials->new };
has dry_run         => 0;
has conformant_only => 0;
has yes             => 0;
has check_login     => 1;
has pull_latest     => 0;

# The answers that confirm a release.
our %YES = map { $_ => 1 } qw{y yes};

=method run

C<(@arguments)>.  Runs the program with the arguments of the command line,
and returns its exit status: 0 when nothing failed, 1 when a release failed,
and 2 for a mistake in the arguments or a run that stopped before the first
release, such as an unanswered question or credentials that PAUSE refused.

=cut

sub run ( $self, @arguments ) {
    my %options;
    my $parsed  = Getopt::Long::GetOptionsFromArray( \@arguments, \%options, qw{dry-run|n conformant-only credentials yes|y skip-login-check pull-latest help|h} );
    my $problem = !$parsed ? q{} : !@arguments && !$options{help} ? "Name at least one checkout.\n" : undef;
    if ( defined $problem || $options{help} ) {
        Pod::Usage::pod2usage( -message => $problem, -exitval => 'NOEXIT', -verbose => 1, -output => defined $problem ? \*STDERR : \*STDOUT );
        return defined $problem ? 2 : 0;
    }
    $self->dry_run( $options{'dry-run'}                 // 0 );
    $self->conformant_only( $options{'conformant-only'} // 0 );
    $self->yes( $options{yes}                           // 0 );
    $self->check_login( $options{'skip-login-check'} ? 0 : 1 );
    $self->pull_latest( $options{'pull-latest'} // 0 );

    my $result = eval {
        $self->credentials->load if $options{credentials} && !$self->dry_run;
        my $plan = $self->plan(@arguments);
        print listing( $plan, $self->dry_run ? 'Would release' : 'To release' );
        return 0 if $self->dry_run;
        return 0 if !@{ $plan->{release} };
        if ( !$self->yes && !$self->confirm($plan) ) {
            print "Nothing was released.\n";
            return 0;
        }
        $self->credentials->ask;
        $self->credentials->check_with_pause if $self->check_login;
        my $outcome = $self->release_all($plan);
        print summary($outcome);
        return @{ $outcome->{failed} } ? 1 : 0;
    };
    return $result if defined $result;
    warn $@;
    return 2;
}

=method plan

C<(@paths)>.  Looks at each path through L</inspect>, and orders the
distributions to release through L<App::BatchRelease::Prereqs/order>.
Returns a hash reference of C<release>, the entries to release, in order,
and C<skipped>, the entries to skip, in the order of the paths.  An entry is
what L</inspect> returns, and an entry to release has C<needs> too, the
names of the distributions of the batch that it requires.  A distribution
whose requirements in the batch form a cycle is skipped, and so is one that
requires such a distribution, directly or through others.  So is one whose requirements cannot be read, and a
second checkout of a distribution that an earlier path already gave.

=cut

sub plan ( $self, @paths ) {
    my ( %due, @skipped );
    for my $path (@paths) {
        my $entry = $self->inspect($path);
        if ( defined $entry->{skip} ) {
            push @skipped, $entry;
        }
        elsif ( my $first = $due{ $entry->{name} } ) {
            push @skipped, { %$entry, skip => "$first->{path} is a checkout of the same distribution, and comes first" };
        }
        else {
            $due{ $entry->{name} } = $entry;
        }
    }

    my %graph;
    for my $name ( sort keys %due ) {
        my $root = $due{$name}{path};
        my $ok   = eval { $graph{$name} = { provides => App::BatchRelease::Prereqs::provides($root), requires => App::BatchRelease::Prereqs::requires($root) }; 1 };
        next if $ok;
        push @skipped, { %{ delete $due{$name} }, skip => 'its requirements could not be read: ' . first_line($@) };
    }
    my $order = App::BatchRelease::Prereqs::order( \%graph );
    for my $name ( sort keys %{ $order->{cycles} } ) {
        push @skipped, { %{ $due{$name} }, skip => 'its requirements form a cycle with ' . join( ', ', @{ $order->{cycles}{$name} } ) . ' of this batch, so no order puts each after the ones it requires' };
    }
    for my $name ( sort keys %{ $order->{blocked} } ) {
        push @skipped, { %{ $due{$name} }, skip => 'requires ' . join( ', ', @{ $order->{blocked}{$name} } ) . ' of this batch, which cannot be released, because of a cycle of requirements' };
    }
    my @release = map { +{ %{ $due{$_} }, needs => $order->{needs}{$_} } } @{ $order->{order} };
    return { release => \@release, skipped => \@skipped };
}

=method inspect

C<($path)>.  An entry for one path: a hash reference of C<path>, and, when
it got that far, C<name>, C<version> and the rest of what
L<App::BatchRelease::State/release_state> returns.  An entry to skip has
C<skip>, the reason.  The path is skipped when:

=over

=item *

it is not a directory, has no F<dist.ini>, or is not the top of a git
checkout, so it is not clearly a Dist::Zilla distribution;

=item *

L</sync> gives a reason: the fetch failed, the default branch has no
upstream, or it is behind its upstream and L</pull_latest> cannot bring it
up to date;

=item *

its F<dist.ini> is not committed on the default branch, or the check of its
state fails;

=item *

its state says that CPAN has its work, or that nothing can tell, or that
its version must be raised first: see L</due>;

=item *

it is due, but the checkout is not on its default branch, or has changes
that are not committed, because C<dzil release> releases the work tree;

=item *

it is due, L</conformant_only> is set, and L</conformance_problem> finds a
problem.

=back

On a dry run, an entry that a pull would change has C<pull>, what the pull
would do, such as C<check out main and fast-forward 2 commits>.  Then its
state is the one that it would have after the pull.

It changes nothing in the work tree of the checkout, unless
L</pull_latest> is set and this is not a dry run.  It fetches, as L</sync>
says.

=cut

sub inspect ( $self, $path ) {
    my %entry = ( path => $path );
    return { %entry, skip => 'not a directory' }                                      if !-d $path;
    return { %entry, skip => 'no dist.ini, so it is not a Dist::Zilla distribution' } if !-e "$path/dist.ini";
    my $source = App::BatchRelease::Source::Git->new( root => $path );
    return { %entry, skip => 'not the top of a git checkout' } if !$source->is_checkout;

    my $sync = eval { $self->sync($source) };
    return { %entry, skip => 'the check of its default branch against its upstream failed: ' . first_line($@) } if !$sync;
    return { %entry, skip => $sync->{skip} }                                                                    if defined $sync->{skip};
    $entry{pull} = $sync->{pull} if defined $sync->{pull};

    my $state = eval { App::BatchRelease::State::release_state( $source, $self->cpan ) };
    return { %entry, skip => 'the check of its state failed: ' . first_line($@) }    if !$state && $@;
    return { %entry, skip => 'its dist.ini is not committed on the default branch' } if !$state;
    %entry = ( %entry, %$state );
    my $reason = due($state);
    return { %entry, skip => $reason } if defined $reason;

    my $branch  = $source->default_branch;
    my $current = $sync->{switch} ? $branch : $source->current_branch // 'a detached head';
    return { %entry, skip => "the checkout is on $current, not on its default branch $branch" } if $current ne $branch;
    my @changes = $source->changes;
    return { %entry, skip => changed(@changes) . ', which dzil release refuses' } if @changes;

    if ( $self->conformant_only && defined( my $problem = conformance_problem($path) ) ) {
        return { %entry, skip => $problem };
    }
    return \%entry;
}

=method sync

C<($source)>, an L<App::BatchRelease::Source::Git>.  Brings the checkout up to
date with its upstream, as far as it may, and says how it stands.  Returns a
hash reference with C<skip>, the reason to skip the checkout, or else with
what a dry run would do, if anything: C<pull>, what L</inspect> says of it,
and C<switch>, true when it would check out the default branch.

First it fetches the remote of the upstream of the default branch, on a dry
run too, because a fetch changes no branch and no work tree.  Then it counts
the commits of the default branch and of its upstream that the other does not
have.  The checkout is skipped:

=over

=item *

when the default branch has no upstream.  Then nothing can tell whether
somebody pushed work that it does not have, so it is skipped rather than
released on a guess.  C<git branch --set-upstream-to> gives it one.

=item *

when the fetch fails, because the counts would come from refs that may be
old.

=item *

without L</pull_latest>, when the default branch is behind its upstream,
because C<dzil release> would upload the old work tree, and
C<[Git::Push]> would refuse the push after the upload.  A branch that is
ahead is not skipped: C<[Git::Push]> pushes its commits.

=item *

with L</pull_latest>, when the default branch is behind and ahead at once,
so that it cannot fast-forward, or when the checkout must change branch or
fast-forward and has changes in the work tree.  It never stashes, merges,
rebases or resets.

=back

With L</pull_latest>, a checkout that is on another branch, or a detached
head, gets the default branch checked out, and a default branch that is
behind is fast-forwarded with C<git pull --ff-only>.  One that is up to date
is not pulled.  On a dry run, neither happens: C<pull> says what would, and
the L<App::BatchRelease::Source::Git/tips> of the source points the default
branch at its upstream, so that the state of the distribution is the one
that the fast-forward would give.

=cut

sub sync ( $self, $source ) {
    my $branch   = $source->default_branch;
    my $upstream = $source->upstream($branch) // return { skip => "its default branch $branch has no upstream, so nothing can tell whether it is behind; git branch --set-upstream-to gives it one" };
    my $fetched  = eval { $source->fetch( $upstream->{remote} ); 1 };
    return { skip => "git fetch $upstream->{remote} failed, so nothing can tell whether $branch is behind $upstream->{name}: " . first_line($@) } if !$fetched;
    my ( $ahead, $behind ) = $source->divergence( $branch, $upstream->{ref} );

    my $behind_by = plural( $behind, 'commit' ) . " behind $upstream->{name}";
    return { skip => $behind_by }                                                                                 if $behind && !$self->pull_latest;
    return {}                                                                                                     if !$self->pull_latest;
    return { skip => "$behind_by and " . plural( $ahead, 'commit' ) . ' ahead of it, so it cannot fast-forward' } if $behind && $ahead;

    my $switch = ( $source->current_branch // q{} ) ne $branch;
    my $pull   = join ' and ', ( $switch ? "check out $branch" : () ), ( $behind ? 'fast-forward ' . plural( $behind, 'commit' ) : () );
    return {} if $pull eq q{};
    my @changes = $source->changes;
    return { skip => changed(@changes) . ", so --pull-latest cannot $pull" } if @changes;

    if ( $self->dry_run ) {
        $source->tips->{$branch} = $upstream->{ref} if $behind;
        return { pull => $pull, switch => $switch };
    }
    my $pulled = eval {
        $source->switch($branch) if $switch;
        $source->pull            if $behind;
        1;
    };
    return { skip => "--pull-latest could not $pull: " . first_line($@) } if !$pulled;
    return {};
}

=func plural

C<($count, $noun)>.  The count and the noun, with an C<s> unless the count is
1, such as C<1 commit> and C<2 commits>.

=cut

sub plural ( $count, $noun ) {
    return "$count $noun" . ( $count == 1 ? q{} : 's' );
}

=func changed

C<(@changes)>, what L<App::BatchRelease::Source::Git/changes> returns.  How
many paths of the work tree are changed or untracked, in words.

=cut

sub changed (@changes) {
    return plural( scalar @changes, 'changed or untracked path' ) . ' in the work tree';
}

=func due

C<($state)>, what L<App::BatchRelease::State/release_state> returns.  Undef
when the distribution is due for a release that C<dzil release> can make,
else the reason that it is not:

=over

=item *

C<never_released> and C<not_uploaded> are due.

=item *

C<unreleased_commits> is due when the version comes from the tags, as with
C<[Git::NextVersion]>, which gives the next release a new version.  With a
C<version> in F<dist.ini>, that version is on CPAN already, PAUSE refuses it
a second time, and C<[Git::Tag]> refuses to write its tag again, so it is not
due until somebody raises the version.

=item *

C<released>, C<no_tag> and C<no_version> are not due.

=back

=cut

sub due ($state) {
    my $kind = $state->{state};
    return "released: CPAN has $state->{version}, and the default branch has nothing after its tag"                                         if $kind eq 'released';
    return 'CPAN has ' . ( $state->{version} // 'releases of it' ) . ', but no tag says which commit, so nothing can tell what is released' if $kind eq 'no_tag';
    return 'its dist.ini sets no version and does not load [Git::NextVersion], so nothing can tell what is released'                        if $kind eq 'no_version';
    if ( $kind eq 'unreleased_commits' && ( $state->{version_from} // q{} ) ne 'tag' ) {
        return plural( $state->{ahead_by}, 'commit' ) . " after the tag $state->{tag}, but dist.ini still says $state->{version}, which CPAN has: raise the version to release them";
    }
    return;
}

=func conformance_problem

C<($root)>.  Undef when the checkout C<$root> is in full conformance, as
L<Dist::Conformance> defines it: L<Dist::Conformance/check> reports no check
as C<fail>, which is when C<conformance check> exits 0.  Else the reason,
which names each check that failed, or says why the check could not run, for
example when the checkout has no F<.conformance.yml>.  It reads the
checkout, and changes nothing in it.  It fetches the standards of a git
source into the cache of L<Dist::Conformance::Source::Git>.

=cut

sub conformance_problem ($root) {
    my $results = eval { Dist::Conformance->new( root => $root )->check };
    return 'the conformance check could not run: ' . first_line($@) if !$results;
    my @failed = map { $_->{check} } grep { $_->{status} eq 'fail' } @$results;
    return 'not in full conformance: ' . join( ', ', @failed ) . ( @failed == 1 ? ' fails' : ' fail' ) if @failed;
    return;
}

=func first_line

C<($message)>.  The first line of C<$message>, without its newline.

=cut

sub first_line ($message) {
    return ( split m{\n}, $message // q{} )[0] // q{};
}

=func describe

C<($entry)>.  The state of an entry to release, in words.

=cut

sub describe ($entry) {
    my $state = $entry->{state};
    return 'never released'                                                        if $state eq 'never_released';
    return "not uploaded, CPAN has $entry->{latest}"                               if $state eq 'not_uploaded';
    return plural( $entry->{ahead_by}, 'commit' ) . " after the tag $entry->{tag}" if $state eq 'unreleased_commits';
    return $state;
}

=func version_of

C<($entry)>.  The version that the release of an entry will have, as far as
this program can tell: the version of F<dist.ini>, or the next after the
version of the last tag when the tags give it.

=cut

sub version_of ($entry) {
    return $entry->{version} // '?' if ( $entry->{version_from} // q{} ) ne 'tag';
    return 'first'                  if !defined $entry->{version};
    return "next after $entry->{version}";
}

=func listing

C<($plan, $verb)>, what L</plan> returns and the words that start the list.
The text of the plan: the distributions to release, in order, each with its
version, its state, the distributions of the batch that it requires and its
path, then the ones to skip, each with its reason.  An entry with C<pull>, from
a dry run, says what the pull would do first.

=cut

sub listing ( $plan, $verb ) {
    my @release = @{ $plan->{release} };
    my @lines   = ( @release ? "$verb, in this order:" : 'Nothing to release.' );
    my $n       = 0;
    for my $entry (@release) {
        my @needs = @{ $entry->{needs} // [] };
        push @lines, sprintf( '  %d. %s %s: %s%s%s', ++$n, $entry->{name}, version_of($entry), describe($entry), ( @needs ? '; after ' . join( ', ', @needs ) : q{} ), pull_note($entry) ), "       $entry->{path}";
    }
    my @skipped = @{ $plan->{skipped} };
    push @lines, 'Skipped:' if @skipped;
    push @lines, map { my $entry = $_; '  ' . label($entry) . ": $entry->{skip}" . pull_note($entry) } @skipped;
    return join q{}, map { "$_\n" } @lines;
}

=func pull_note

C<($entry)>.  What the pull of a dry run would do for the entry, as words to
append to its line, such as C<; would check out main and fast-forward 2
commits first>.  Empty when the entry has no C<pull>.

=cut

sub pull_note ($entry) {
    return defined $entry->{pull} ? "; would $entry->{pull} first" : q{};
}

=func label

C<($entry)>.  The name of the distribution of an entry and its path, or only
the path when it has no name.

=cut

sub label ($entry) {
    return defined $entry->{name} ? "$entry->{name} ($entry->{path})" : $entry->{path};
}

=method confirm

C<($plan)>.  Asks whether to release the distributions of the plan, and
returns true for C<y> or C<yes>, in any case.  It asks at F</dev/tty> when
the credentials came on standard input.  It dies when nobody can answer, and
says to pass C<--yes>.

=cut

sub confirm ( $self, $plan ) {
    my @at;
    if ( $self->credentials->from_stdin ) {
        @at = App::BatchRelease::Prompt::at_terminal('the confirmation');
    }
    elsif ( !App::BatchRelease::Prompt::interactive() ) {
        die "Nobody can confirm the release: standard input is not a terminal.\nPass --yes to release without asking.\n";
    }
    my $count  = @{ $plan->{release} };
    my $answer = App::BatchRelease::Prompt::ask( 'Release these ' . plural( $count, 'distribution' ) . ' to CPAN? [y/N]', @at );
    return 0 if !$answer;
    my $typed = lc "$answer";
    $typed =~ s{\A\s+|\s+\z}{}g;
    return $YES{$typed} ? 1 : 0;
}

=method release_all

C<($plan)>.  Releases each distribution of the plan, in order, through
L<App::BatchRelease::Release/release>.  A distribution that requires one of
the batch that was not released, because its release failed or because it
was skipped for that reason, is skipped.  Returns a hash reference of
C<released>, C<skipped> and C<failed>, each a list of entries.  The skipped
ones are those of the plan and then those that this skipped, each with
C<skip>, and a failed one has C<error>.

The tests of a release run against the modules that are installed, and a
distribution of the batch that was released a moment ago is not installed,
nor yet indexed by CPAN.  So each release gets, through the option C<lib> of
L<App::BatchRelease::Release/release>, the F<lib/> of the build of each
distribution of the batch that it requires, directly or not.  The build is
what went to CPAN, with the versions that C<[PkgVersion]> wrote.

When the credentials came on standard input, each release reads its own
questions from L<App::BatchRelease::Prompt/answers_from>, the terminal or,
without one, F</dev/null>.

=cut

sub release_all ( $self, $plan ) {
    my ( %lib, %reason, @released, @failed );
    my @skipped = @{ $plan->{skipped} };
    my @stdin   = $self->credentials->from_stdin ? ( stdin => App::BatchRelease::Prompt::answers_from() ) : ();
    for my $entry ( @{ $plan->{release} } ) {
        my ($blocked) = grep { !$lib{$_} } @{ $entry->{needs} // [] };
        if ( defined $blocked ) {
            my $skip = { %$entry, skip => "requires $blocked, which $reason{$blocked}" };
            push @skipped, $skip;
            $reason{ $entry->{name} } = 'was skipped';
            next;
        }
        print "\n== Releasing $entry->{name} from $entry->{path}\n";
        my @lib     = List::Util::uniq( map { @{ $lib{$_} } } @{ $entry->{needs} // [] } );
        my $outcome = App::BatchRelease::Release::release( $entry->{path}, $self->credentials, @stdin, @lib ? ( lib => \@lib ) : () );
        if ( defined $outcome->{error} ) {
            push @failed, { %$entry, error => $outcome->{error} };
            $reason{ $entry->{name} } = 'failed';
            next;
        }
        push @released, $entry;
        $lib{ $entry->{name} } = [ ( defined $outcome->{built} ? "$outcome->{built}/lib" : () ), @lib ];
    }
    return { released => \@released, skipped => \@skipped, failed => \@failed };
}

=func summary

C<($outcome)>, what L</release_all> returns.  The text of the summary: the
distributions that were released, skipped, each with the reason, and
failed, each with the error.

=cut

sub summary ($outcome) {
    my ( $released, $skipped, $failed ) = @{$outcome}{qw{released skipped failed}};
    my @lines = ( q{}, 'Summary', sprintf( 'Released (%d):', scalar @$released ) );
    push @lines, map { my $entry = $_; "  $entry->{name} " . version_of($entry) } @$released;
    push @lines, sprintf( 'Skipped (%d):', scalar @$skipped );
    push @lines, map { my $entry = $_; '  ' . label($entry) . ": $entry->{skip}" } @$skipped;
    push @lines, sprintf( 'Failed (%d):', scalar @$failed );
    push @lines, map { my $entry = $_; '  ' . label($entry) . ": $entry->{error}" } @$failed;
    return join q{}, map { "$_\n" } @lines;
}

1;
