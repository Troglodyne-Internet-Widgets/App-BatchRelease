package App::BatchRelease::State;

# ABSTRACT: Whether the work of a Dist::Zilla distribution is all on CPAN

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';

use Config::INI::Reader();
use List::Util();
use version();

=head1 SYNOPSIS

    use 5.040;
    use App::BatchRelease::MetaCPAN;
    use App::BatchRelease::Source::Git;
    use App::BatchRelease::State;

    my $source = App::BatchRelease::Source::Git->new( root => '/bogus/Foo-Bar' );
    my $cpan   = App::BatchRelease::MetaCPAN->new;
    my $state  = App::BatchRelease::State::release_state( $source, $cpan );
    print "$state->{name}: $state->{state}\n" if $state;

=head1 DESCRIPTION

L</release_state> answers one question about a distribution that
Dist::Zilla builds: does CPAN have all of its work?  It reads F<dist.ini>,
asks MetaCPAN for the versions of the distribution, and compares the tag of
the released version with the default branch.

It does not read files or run git itself.  It asks a I<source>, so that the
same answer comes from a checkout on this machine and from a repository on a
forge.  L<App::BatchRelease::Source::Git> is the source for a local checkout.
A caller that reads a repository through the GitHub API writes a source with
the same five methods.

=head1 THE SOURCE

A source is any object with these methods:

=over

=item id

A name for the repository, which the result carries as C<repo>, such as the
path of a checkout or C<Owner/Name>.

=item file($path)

The content of the file at C<$path> on the default branch, or undef when it
is not there.  Only F<dist.ini> is asked for.  It dies when it cannot tell.

=item default_branch

The name of the default branch.

=item compare($tag, $branch)

Undef when the tag C<$tag> does not exist.  Else a hash reference of
C<ahead_by>, the count of commits on C<$branch> after the tag, and
C<commits>, some or all of them, oldest first, each a hash reference of
C<sha>, C<subject>, the first line of its message, and C<url>, which may be
undef.  The tag must be looked up as a tag, so that a branch with the name of
a version cannot answer for it.

=item tags

The names of all the tags.  Only asked for a F<dist.ini> that sets no
C<version> and loads C<[Git::NextVersion]>.

=back

The client of MetaCPAN is any object with a C<versions($dist)> method that
returns the version of each release of the distribution, newest first, as
L<App::BatchRelease::MetaCPAN/versions> does.

=func release_state

C<($source, $cpan)>.  Undef when the source has no F<dist.ini>.  Else a hash
reference of C<repo>, the C<id> of the source, C<name> and C<version>, and
C<state>, one of:

=over

=item C<no_version>

The F<dist.ini> sets no C<version>, and does not load C<[Git::NextVersion]>,
so there is no version to look for.  Then the hash has no C<version>.

=item C<never_released>

MetaCPAN has no release of the distribution.

=item C<not_uploaded>

MetaCPAN has releases of the distribution, but not this version: the version
was raised and not uploaded.  C<latest> is the newest version on MetaCPAN.

=item C<no_tag>

This version is on MetaCPAN, but the repository has no tag C<$version> or
C<v$version>, so nothing can tell which commit it released.  C<[Git::Tag]>
writes one or the other, by its C<tag_format>.

=item C<unreleased_commits>

The default branch has commits after the tag of this version.  C<tag> is the
tag, C<ahead_by> the count of those commits, and C<commits> what
C<compare> of the source gave of them, as L</THE SOURCE> says.

=item C<released>

The default branch has nothing after the tag of this version.

=back

C<name> and C<version> come from the root section of F<dist.ini>.  A
F<dist.ini> that sets no C<version> but loads C<[Git::NextVersion]> gets its
version from git, as that plugin does: the highest tag that matches the
C<version_regexp> of the plugin, default C<^v(.+)$>.  Then C<version> is the
version of that tag, which is the last release and not the next, the hash has
C<version_from> set to C<tag>, and the tag is the only one compared.  Such a
distribution with no matching tag has no C<version>, and is
C<never_released>, or C<no_tag> when MetaCPAN has releases of it.  Only a
section named C<[Git::NextVersion]> in the F<dist.ini> counts.  A bundle that
loads the plugin is not seen, and gives C<no_version>.

It dies when the source or MetaCPAN fails, or when the F<dist.ini> does not
parse or names no distribution.

=cut

sub release_state ( $source, $cpan ) {
    my $ini    = $source->file('dist.ini') // return;
    my $config = Config::INI::Reader->read_string($ini);
    my $root   = $config->{_} // {};
    my $id     = $source->id;
    my %dist   = ( repo => $id, name => $root->{name} // die "The dist.ini of $id names no distribution\n" );

    my @tags;
    if ( defined $root->{version} ) {
        $dist{version} = $root->{version};
        @tags = ( $root->{version}, "v$root->{version}" );
    }
    elsif ( defined( my $regexp = next_version_regexp($config) ) ) {
        $dist{version_from} = 'tag';
        if ( my $last = last_version_tag( $regexp, $source->tags ) ) {
            $dist{version} = $last->{version};
            @tags = ( $last->{tag} );
        }
    }
    else {
        return { %dist, state => 'no_version' };
    }

    my @versions = @{ $cpan->versions( $dist{name} ) };
    return { %dist, state => 'never_released' } if !@versions;
    return { %dist, state => 'no_tag' }         if !defined $dist{version};
    return { %dist, state => 'not_uploaded', latest => $versions[0] } if !List::Util::any { $_ eq $dist{version} } @versions;

    my $branch = $source->default_branch;
    for my $tag (@tags) {
        my $compare = $source->compare( $tag, $branch ) // next;
        return { %dist, state => 'released' } if !$compare->{ahead_by};
        return { %dist, state => 'unreleased_commits', tag => $tag, ahead_by => $compare->{ahead_by}, commits => $compare->{commits} // [] };
    }
    return { %dist, state => 'no_tag' };
}

=func next_version_regexp

C<($config)>, a F<dist.ini> as L<Config::INI::Reader> reads it.  The
C<version_regexp> of its C<[Git::NextVersion]> section, or the default of the
plugin, C<^v(.+)$>, when the section sets none.  Undef when there is no such
section.  A section with a name, such as C<[Git::NextVersion / Next]>, counts.

=cut

sub next_version_regexp ($config) {
    my ($section) = grep { m{\AGit::NextVersion(?:\s*/.*)?\z} } sort keys %$config;
    return if !defined $section;
    return $config->{$section}{version_regexp} // '^v(.+)$';
}

=func last_version_tag

C<($regexp, @tags)>.  The tag whose first capture of C<$regexp> is the
highest version, as a hash reference of C<tag> and C<version>, the capture.
Undef when no tag matches, or no capture is a version that L<version> can
read.

=cut

sub last_version_tag ( $regexp, @tags ) {
    my $pattern = qr{$regexp};
    my @found;
    for my $tag (@tags) {
        my ($captured) = $tag =~ $pattern;
        next if !defined $captured;
        my $parsed = eval { version->parse($captured) } // next;
        push @found, { tag => $tag, version => $captured, parsed => $parsed };
    }
    my $last = List::Util::reduce { $b->{parsed} > $a->{parsed} ? $b : $a } @found;
    return if !$last;
    return { tag => $last->{tag}, version => $last->{version} };
}

1;
