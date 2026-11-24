package App::BatchRelease::Release;

# ABSTRACT: Run the release of one Dist::Zilla distribution, with credentials handed over in memory

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use Dist::Zilla::App();
use Mojo::File();
use POSIX();

=head1 SYNOPSIS

    use 5.040;
    use App::BatchRelease::Credentials;
    use App::BatchRelease::Release;

    my $credentials = App::BatchRelease::Credentials->new( username => 'TESTER', password => 'bogus' );
    my $outcome = App::BatchRelease::Release::release( '/bogus/Foo-Bar', $credentials );
    print defined $outcome->{error} ? "failed: $outcome->{error}\n" : "released from $outcome->{built}\n";

=head1 DESCRIPTION

L</release> does what C<dzil release> does in a checkout, with one change:
the C<[UploadToCPAN]> plugins of the distribution get the PAUSE username and
password from this program, so none of them asks for them, and none reads
F<~/.pause>.

=head2 HOW THE CREDENTIALS REACH UPLOADTOCPAN

L<Dist::Zilla::Plugin::UploadToCPAN> takes its C<username> and C<password>
from the first of: its C<credentials_stash>, default C<%PAUSE>, as
F<~/.dzil/config.ini> sets it; F<~/.pause>; a prompt.  Both attributes are
lazy, and C<password> takes no value from F<dist.ini>.

This program runs the release in a child process, made with C<fork>, so the
child has the credentials in its memory from the parent, and nothing carries
them between the two.  The child builds the Dist::Zilla object as the
C<dzil release> command builds it, with L<Dist::Zilla::App>, so the global
configuration and its stashes still apply.  Then, before the release starts,
it sets the C<username> and C<password> of every plugin that is an
L<Dist::Zilla::Plugin::UploadToCPAN>, through the meta-object of the class.
A lazy attribute that has a value does not run its default, so neither a
stash, nor F<~/.pause>, nor a prompt is asked.  That holds whatever the
F<dist.ini> names as its stash.

A child also keeps the batch apart: each release loads the plugins of its own
distribution into a fresh process, and a release that dies, or changes the
directory or the environment, takes only its own process with it.

=func release

C<($root, $credentials, %options)>.  Releases the distribution in the
checkout C<$root>, in a child process, and waits for it.  Returns a hash
reference of C<error>, undef when the release succeeded, else the reason
that it failed, and C<built>, the directory of the build that the child
released, when it got that far.  The output of the release goes to the
standard output and the standard error of this program.

With C<< stdin => PATH >>, the child reads its standard input from C<PATH>,
for the questions that the plugins of the distribution ask, such as
C<[ConfirmRelease]>.  The caller passes F</dev/tty> when its own standard
input carried the credentials.

With C<< lib => \@dirs >>, the child puts C<@dirs> at the front of
C<PERL5LIB>, so that the tests of the release, which C<[TestRelease]> runs
in another process, find modules that are not installed, such as those of
a distribution of the batch that was released a moment ago.

=cut

sub release ( $root, $credentials, %options ) {
    STDOUT->flush;
    STDERR->flush;
    pipe( my $read, my $write ) or return { error => "pipe: $!" };
    my $pid = fork // return { error => "fork: $!" };
    if ( !$pid ) {
        close $read or POSIX::_exit(1);
        child( $root, $credentials, $write, %options );
    }
    close $write or return { error => "close: $!" };
    my $built = do { local $/ = undef; <$read> }
      // q{};
    close $read or return { error => "close: $!" };
    chomp $built;
    waitpid( $pid, 0 ) == $pid or return { error => "waitpid: $!" };
    my $status  = $?;
    my %outcome = ( built => $built eq q{} ? undef : $built );
    return { %outcome, error => undef }                                                   if !$status;
    return { %outcome, error => 'the release was killed by signal ' . ( $status & 127 ) } if $status & 127;
    return { %outcome, error => 'the release exited ' . ( $status >> 8 ) };
}

=func child

C<($root, $credentials, $report, %options)>, as L</release> takes them, and
the handle C<$report> to the parent.  The body of the child process: runs
L</dzil_release>, writes the directory of the build to C<$report>, and ends
the process, with status 0 when it succeeded and 1 when it died, after it
prints the error.  It ends with C<POSIX::_exit>, so that no C<END> block and
no destructor of an object of the parent, such as a temporary file, runs in
the child.

=cut

sub child ( $root, $credentials, $report, %options ) {    ## no critic (Subroutines::RequireFinalReturn) It ends in _exit, which does not return.
    my $ok = eval {
        if ( defined $options{stdin} ) {
            open( STDIN, '<', $options{stdin} ) or die "Cannot read standard input from $options{stdin}: $!\n";
        }
        local $ENV{PERL5LIB} = join q{:}, grep { $_ ne q{} } @{ $options{lib} // [] }, $ENV{PERL5LIB} // q{};
        my $built = dzil_release( $root, $credentials );
        print {$report} "$built\n" if defined $built;
        1;
    };

    # The transcript of the batch, for the person who runs it, and not a diagnostic of this code.
    print {*STDERR} "The release of $root failed: $@" if !$ok;    ## no critic (ProhibitPrintSTDERR)
    STDOUT->flush;
    STDERR->flush;
    close $report or $ok = 0;
    POSIX::_exit( $ok ? 0 : 1 );
}

=func dzil_release

C<($root, $credentials)>.  Changes to C<$root> and runs the release there,
in this process, as C<dzil release> does, after it hands the credentials to
the Dist::Zilla object through L</hand_credentials>.  Returns the absolute
path of the directory of the build, or undef when Dist::Zilla does not say.
Dies as the release dies.

=cut

sub dzil_release ( $root, $credentials ) {
    chdir $root or die "chdir $root: $!\n";
    my $app = Dist::Zilla::App->new;
    my ( $command, $options, @args ) = $app->prepare_command('release');
    my $zilla = $command->zilla;
    hand_credentials( $zilla, $credentials );
    $app->execute_command( $command, $options, @args );
    my $built = $zilla->built_in // return;
    return Mojo::File->new("$built")->to_abs->to_string;
}

=func hand_credentials

C<($zilla, $credentials)>.  Sets the C<username> and C<password> of every
plugin of the Dist::Zilla object C<$zilla> that is an
L<Dist::Zilla::Plugin::UploadToCPAN>, from C<$credentials>, an
L<App::BatchRelease::Credentials>.  Returns the count of such plugins.

=cut

sub hand_credentials ( $zilla, $credentials ) {
    my @uploaders = grep { $_->isa('Dist::Zilla::Plugin::UploadToCPAN') } @{ $zilla->plugins };
    for my $plugin (@uploaders) {
        my $meta = $plugin->meta;
        $meta->find_attribute_by_name('username')->set_value( $plugin, $credentials->username );
        $meta->find_attribute_by_name('password')->set_value( $plugin, $credentials->password );
    }
    return scalar @uploaders;
}

1;
