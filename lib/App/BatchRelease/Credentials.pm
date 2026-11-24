package App::BatchRelease::Credentials;

# ABSTRACT: The PAUSE username and password, asked for once, before any build

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use Mojo::URL       ();
use Mojo::UserAgent ();

use App::BatchRelease::Prompt();

=head1 SYNOPSIS

    use 5.040;
    use App::BatchRelease::Credentials;

    my $credentials = App::BatchRelease::Credentials->new;
    $credentials->load(\*STDIN);      # only when asked to, with --credentials
    $credentials->ask;                # whatever the block did not give
    $credentials->check_with_pause;   # dies when PAUSE refuses them

=head1 DESCRIPTION

A batch uploads many distributions, and each upload needs the PAUSE username
and password.  This asks for them once, at the start, before any build, and
keeps them in memory for the rest of the run.  Nothing here writes them to a
file, puts them on a command line or in the environment.

=head2 A BLOCK ON STANDARD INPUT

A run that nobody watches cannot answer a prompt.  So, as trog-provisioner's
C<Trog::Credentials> does, the caller can give the credentials on standard
input, before anything runs, as a block of C<name: value> lines that ends at a
blank line or at the end of the input:

    username: TESTER
    password: correct horse battery staple

The names are C<username> and C<password>.  Any other name is an error, and
is not ignored, because a misspelled name that silently meant "ask for it"
makes a run that waits for an answer nobody gives.  Whitespace around the
value stays, because a password can contain some.

Standard input is the one channel that is not the process table, the
environment or a file.  Anybody can read the arguments of a process while it
lives, and anything that runs as the same user can read its environment, which
every child inherits.  A file has to be created, given its mode and deleted,
with no failure in between.  A pipe exists only while the two ends talk.

Nothing reads the block until something calls L</load>, which the option
C<--credentials> of L<batch-release> does.  A read that nobody asked for
hangs when the caller has nothing to give and never closes its end.

=attr username

The PAUSE username.

=attr password

The PAUSE password.

=attr from_stdin

True when L</load> read the block, so standard input is spoken for, and
every later question goes to the terminal.

=cut

has 'username';
has 'password';
has from_stdin => 0;

# The names that a block may give.
our %KNOWN = map { $_ => 1 } qw{username password};

# Where check_with_pause asks.  The page answers 401 without a valid login.
our $PAUSE_LOGIN = 'https://pause.perl.org/pause/authenquery';

=method load

C<($fh)>.  Reads the block from C<$fh>, default standard input, and keeps each
value under its name.  Returns the object.  It dies when a line is not
C<name: value>, or names something other than C<username> or C<password>.

=cut

sub load ( $self, $fh = \*STDIN ) {
    $self->from_stdin(1);
    while ( my $line = <$fh> ) {
        chomp $line;
        last if $line eq q{};
        my ( $name, $value ) = $line =~ m{\A(\w+):[ ]?(\N*)\z};
        die "Could not read the credentials given on standard input.\nExpected 'name: value', got a line that is not.\n" if !defined $name;
        die "Unknown credential '$name' given on standard input.\nKnown names: " . join( ', ', sort keys %KNOWN ) . "\n" if !$KNOWN{$name};
        $self->$name($value);
    }
    return $self;
}

# True for a credential that was given and is not empty.  PAUSE takes no empty one.
my sub filled ($value) { return ( $value // q{} ) ne q{} }

=method ask

Asks for the username, and then for the password, masked, unless each is
already there.  If L</from_stdin>, it asks at F</dev/tty>.  Returns the
object.  It dies when the input ends before an answer, when an answer is
empty, because PAUSE takes no empty username or password, and when nobody can
answer: when standard input is not a terminal and the block was not read, or
there is no terminal.

=cut

sub ask ($self) {
    return $self if filled( $self->username ) && filled( $self->password );
    my @at;
    if ( $self->from_stdin ) {
        @at = App::BatchRelease::Prompt::at_terminal('the PAUSE credentials');
    }
    elsif ( !App::BatchRelease::Prompt::interactive() ) {
        die "Nobody can type the PAUSE credentials: standard input is not a terminal.\nGive them on standard input with --credentials.\n";
    }
    if ( !filled( $self->username ) ) {
        $self->username( typed( App::BatchRelease::Prompt::ask( 'PAUSE username:', @at ), 'the PAUSE username' ) );
    }
    if ( !filled( $self->password ) ) {
        my $user = $self->username;
        $self->password( typed( App::BatchRelease::Prompt::ask( "PAUSE password for $user:", -echo => '*', @at ), 'the PAUSE password' ) );
    }
    return $self;
}

=func typed

C<($answer, $what)>.  The string of an answer of
L<App::BatchRelease::Prompt/ask>.  It dies, naming C<$what>, when no line
arrived or the line is empty.

=cut

sub typed ( $answer, $what ) {
    die "Nothing was typed for $what: its input ended before an answer.\n" if !$answer;
    my $typed = "$answer";
    die "An empty answer for $what: PAUSE takes no empty one.\n" if $typed eq q{};
    return $typed;
}

=method check_with_pause

C<($ua)>, default a new L<Mojo::UserAgent>.  Logs in to PAUSE at
C<$PAUSE_LOGIN> with the credentials, and changes nothing there.  Returns 1
when PAUSE takes them.  It dies when PAUSE answers 401, so that a mistyped
password stops the run before the first build, rather than after each build
of the batch.  It warns and returns 0 when PAUSE gives no answer or another
error, because the uploads may still work.

=cut

sub check_with_pause ( $self, $ua = Mojo::UserAgent->new( max_redirects => 3 ) ) {
    my $url  = Mojo::URL->new($PAUSE_LOGIN)->userinfo( $self->username . q{:} . $self->password );
    my $tx   = $ua->get($url);
    my $code = $tx->res->code;
    die "PAUSE refused the username and password.\n" if ( $code // 0 ) == 401;
    return 1                                         if $code && $code < 400;
    warn "Could not check the PAUSE login, so the run goes on: " . ( $code ? "PAUSE answered $code" : 'no answer: ' . ( $tx->error->{message} // 'unknown' ) ) . "\n";
    return 0;
}

1;
