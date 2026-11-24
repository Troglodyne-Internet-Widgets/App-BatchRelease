#!perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use FindBin::libs;

use App::BatchRelease::State();

# A fake source, as App::BatchRelease::State describes one: the files, the
# tags with how far the branch is ahead of each, and what it was asked.
package Fake::Source {
    use Mojo::Base -base, -signatures;
    has id             => 'Test-Org/test-dist';
    has files          => sub { {} };
    has ahead          => sub { {} };
    has default_branch => 'main';
    has asked          => sub { [] };
    sub file ( $self, $path ) { return $self->files->{$path} }
    sub tags ($self)          { my @tags = sort keys %{ $self->ahead }; return @tags }

    sub compare ( $self, $tag, $branch ) {
        push @{ $self->asked }, "$tag..$branch";
        my $ahead = $self->ahead->{$tag} // return;
        return { ahead_by => scalar @$ahead, commits => [ map { { sha => $_, subject => "subject of $_", url => undef } } @$ahead ] };
    }
}

# A fake MetaCPAN, with the versions of each distribution, newest first.
package Fake::CPAN {
    use Mojo::Base -base, -signatures;
    has versions_of => sub { {} };
    sub versions ( $self, $dist ) { return $self->versions_of->{$dist} // [] }
}

package main;

my $INI = "name = Test-Dist\nversion = 0.002\n";

sub state_of ( $ini, $ahead, $versions ) {
    my $source = Fake::Source->new( files => { defined $ini ? ( 'dist.ini' => $ini ) : () }, ahead => $ahead );
    my $cpan   = Fake::CPAN->new( versions_of => { 'Test-Dist' => $versions } );
    my $state  = App::BatchRelease::State::release_state( $source, $cpan );
    return ( $state, $source );
}

subtest 'a version in dist.ini' => sub {
    is( ( state_of( undef, {}, [] ) )[0],                              undef,                                                                                                                 'no dist.ini, no answer: it is not a Dist::Zilla distribution' );
    is( ( state_of( $INI, {}, [] ) )[0],                               { repo => 'Test-Org/test-dist', name => 'Test-Dist', version => '0.002', state => 'never_released' },                  'MetaCPAN has no release' );
    is( ( state_of( $INI, {}, [qw{0.001 0.0005}] ) )[0],               { repo => 'Test-Org/test-dist', name => 'Test-Dist', version => '0.002', state => 'not_uploaded', latest => '0.001' }, 'MetaCPAN lacks this version, and latest is the newest it has' );
    is( ( state_of( $INI, { '0.002' => [] }, [qw{0.002 0.001}] ) )[0], { repo => 'Test-Org/test-dist', name => 'Test-Dist', version => '0.002', state => 'released' },                        'nothing after the tag' );

    my ( $state, $source ) = state_of( $INI, { 'v0.002' => [qw{aaa bbb}] }, [qw{0.002}] );
    is(
        $state,
        { repo => 'Test-Org/test-dist', name => 'Test-Dist', version => '0.002', state => 'unreleased_commits', tag => 'v0.002', ahead_by => 2, commits => [ { sha => 'aaa', subject => 'subject of aaa', url => undef }, { sha => 'bbb', subject => 'subject of bbb', url => undef } ] },
        'commits after the tag vVERSION, oldest first'
    );
    is( $source->asked, [qw{0.002..main v0.002..main}], 'the tag VERSION is tried first, then vVERSION, each against the default branch' );

    is( ( state_of( $INI,                 { 'v0.001' => [] }, [qw{0.002}] ) )[0]{state}, 'no_tag',                                                                     'a released version with neither tag cannot tell which commit it released' );
    is( ( state_of( "name = Test-Dist\n", {},                 [qw{0.002}] ) )[0],        { repo => 'Test-Org/test-dist', name => 'Test-Dist', state => 'no_version' }, 'no version and no [Git::NextVersion], and nothing is asked of MetaCPAN' );
    is( dies { state_of( "version = 1\n", {}, [] ) }, "The dist.ini of Test-Org/test-dist names no distribution\n", 'a dist.ini without a name dies, naming the repository' );
};

subtest 'a version from [Git::NextVersion]' => sub {
    my $next = "name = Test-Dist\n[Git::NextVersion]\nfirst_version = 0.001\nversion_regexp = ^v?(\\d+\\.\\d+)\$\n";
    my ( $state, $source ) = state_of( $next, { '0.002' => ['ccc'], '0.010' => [qw{ddd eee}], 'not-a-version' => [] }, [qw{0.010 0.002}] );
    is( $state->{state},                                      'unreleased_commits',    'commits after the highest version tag' );
    is( [ @{$state}{qw{version version_from tag ahead_by}} ], [qw{0.010 tag 0.010 2}], 'the version is that of the highest tag, by version and not by string, which says that 0.002 sorts after 0.010' );
    is( $source->asked,                                       ['0.010..main'],         'only the tag that gave the version is compared' );

    is( ( state_of( $next, { '0.010' => [] }, [qw{0.010}] ) )[0]{state}, 'released',                                                                                                                                   'nothing after the highest tag' );
    is( ( state_of( $next, { '0.010' => [] }, [qw{0.002}] ) )[0],        { repo => 'Test-Org/test-dist', name => 'Test-Dist', version => '0.010', version_from => 'tag', state => 'not_uploaded', latest => '0.002' }, 'a tag that MetaCPAN does not have' );
    is( ( state_of( $next, {}, [] ) )[0],                                { repo => 'Test-Org/test-dist', name => 'Test-Dist', version_from => 'tag', state => 'never_released' },                                      'no tag and no release: never released, with no version' );
    is( ( state_of( $next, {}, [qw{0.001}] ) )[0]{state},                'no_tag',                                                                                                                                     'no tag, but releases on MetaCPAN: nothing can tell which commit' );

    my $default = "name = Test-Dist\n[Git::NextVersion / Next]\n";
    is( ( state_of( $default, { 'v1.5' => ['fff'], '2.0' => [] }, [qw{1.5}] ) )[0]{tag}, 'v1.5', 'a named section counts, and without version_regexp the default ^v(.+)$ takes only the tags with a v' );
};

subtest next_version_regexp => sub {
    is( App::BatchRelease::State::next_version_regexp( { _                   => {} } ),                              undef,     'no section, no regexp' );
    is( App::BatchRelease::State::next_version_regexp( { 'Git::NextVersion'  => {} } ),                              '^v(.+)$', 'the default of the plugin' );
    is( App::BatchRelease::State::next_version_regexp( { 'Git::NextVersion'  => { version_regexp => '^(\d+)$' } } ), '^(\d+)$', 'the regexp of the section' );
    is( App::BatchRelease::State::next_version_regexp( { 'Git::NextVersionX' => {} } ),                              undef,     'a plugin whose name only starts the same does not count' );
};

subtest last_version_tag => sub {
    is( App::BatchRelease::State::last_version_tag( '^v(.+)$', qw{v1.10 v1.9 v1.2} ), { tag => 'v1.9', version => '1.9' },       'the highest version, as version compares decimal versions: 1.9 is above 1.10, which is 1.100' );
    is( App::BatchRelease::State::last_version_tag( '^v(.+)$', qw{v1.2.9 v1.2.10} ),  { tag => 'v1.2.10', version => '1.2.10' }, 'and dotted ones by each part' );
    is( App::BatchRelease::State::last_version_tag( '^v(.+)$', qw{1.0 release} ),     undef,                                     'no tag matches' );
    is( App::BatchRelease::State::last_version_tag( '^v(.+)$', qw{vfoo v0.5} ),       { tag => 'v0.5', version => '0.5' },       'a capture that is not a version is ignored' );
};

done_testing;
