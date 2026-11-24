package App::BatchRelease::Prompt;

# ABSTRACT: Ask a person a question, also when the output is redirected

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';

use IO::Interactive::Tiny();
use IO::Prompter();

=head1 SYNOPSIS

    use 5.040;
    use App::BatchRelease::Prompt;

    my $answer = App::BatchRelease::Prompt::ask('Go on? [y/N]');
    my $secret = App::BatchRelease::Prompt::ask( 'Password:', -echo => '*' );

=head1 DESCRIPTION

Every question that the program asks goes through L</ask>, over
L<IO::Prompter>.  The two problems that it solves are those that
trog-provisioner's C<Trog::Utils::prompt> solves, and in the same way.

=func ask

C<($message, %options)>.  Asks the question C<$message> and returns what
the person typed, as L<IO::Prompter/prompt> returns it: an object that is
false when the input ended before an answer, and true for any line, an empty
one too.  C<%options> go to L<IO::Prompter> unchanged.  For example, C<-echo>
masks what the person types, and C<-in> and C<-out> ask somewhere other than
standard input.

L<IO::Prompter> reads from C<*ARGV>, so it dies with C<Can't open *ARGV> in a
program that has arguments, such as the paths of checkouts.  This makes
C<*ARGV> C<local> to the call.

If standard input is a terminal and the output is not, for example under
C<&E<gt> file>, the question is asked at F</dev/tty>, and the answer is still
read from standard input.  Without that, L<IO::Prompter> shows neither the
question nor the masked echo, and the program waits with nothing on the
screen.  A C<-out> from the caller is used as given.

=cut

# Where a question goes when the output is redirected, and where the
# questions go when standard input is spoken for.  A test points it at a file.
our $TERMINAL = '/dev/tty';

sub ask ( $message, %options ) {
    my $tty;
    if ( !exists $options{-out} && output_is_redirected() && open( my $fh, '>>', $TERMINAL ) ) {    ## no critic (InputOutput::RequireBriefOpen)
        $tty = $options{-out} = $fh;
    }

    local *ARGV = join q{ }, @ARGV;
    my $answer = IO::Prompter::prompt( $message, %options );
    close($tty) or die "Cannot close $TERMINAL: $!\n" if $tty;
    return $answer;
}

=func at_terminal

C<($what)>.  The options C<-in> and C<-out> for L</ask> that ask at
F</dev/tty>, for when standard input is spoken for, as when the credentials
came on it.  It dies, naming C<$what>, when there is no terminal.

=cut

# The handles go back to the caller, who asks its question through them.
sub at_terminal ($what) {
    open( my $in,  '<',  $TERMINAL ) or die "Cannot ask for $what at a terminal: $TERMINAL: $!\n";    ## no critic (InputOutput::RequireBriefOpen)
    open( my $out, '>>', $TERMINAL ) or die "Cannot ask for $what at a terminal: $TERMINAL: $!\n";    ## no critic (InputOutput::RequireBriefOpen)
    return ( -in => $in, -out => $out );
}

=func answers_from

The path that a child process reads its answers from when standard input
is spoken for: F</dev/tty> when this process can open it, else F</dev/null>,
where a question gets the end of the input and takes its default.  A process
with no controlling terminal can see F</dev/tty>, and even read its mode, and
still fails to open it, so this opens it to find out.

=cut

sub answers_from () {
    open( my $fh, '<', $TERMINAL ) or return '/dev/null';
    close $fh                      or return '/dev/null';
    return $TERMINAL;
}

=func interactive

1 when a person can answer a question on standard input: standard input and
the selected output are both terminals.  Else 0.  A question that nobody
answers does not fail.  It stops the run until something kills it.  So a
caller asks this before it asks a question.

=cut

sub interactive () {
    return IO::Interactive::Tiny::is_interactive() ? 1 : 0;
}

=func output_is_redirected

True when standard input is a terminal and the selected output is not.  Then
a person can type an answer but cannot see the question.

=cut

sub output_is_redirected () {
    return IO::Interactive::Tiny::is_interactive(*STDIN) && !IO::Interactive::Tiny::is_interactive();
}

1;
