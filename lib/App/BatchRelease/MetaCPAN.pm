package App::BatchRelease::MetaCPAN;

# ABSTRACT: Ask MetaCPAN which versions of a distribution it has

use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Mojo::Base -base, -signatures;

use Mojo::URL       ();
use Mojo::UserAgent ();
use Mojo::Util      ();
use Sub::Retry      qw{retry};

=attr api

The API base URL.

=cut

has api => 'https://fastapi.metacpan.org/v1';

=attr timeout

Seconds for each request.

=cut

has timeout => 30;

=attr ua

The L<Mojo::UserAgent>.

=cut

has ua => sub ($self) {
    my $ua = Mojo::UserAgent->new( max_redirects => 3 );
    $ua->connect_timeout(10)->request_timeout( $self->timeout )->inactivity_timeout( $self->timeout );
    return $ua;
};

=attr attempts

How many times L</get> sends a request that gets no answer.

=cut

has attempts => 2;

=attr retry_delay

Seconds between two of those L</attempts>.

=cut

has retry_delay => 1;

=method get

C<($path)>.  The decoded JSON of the answer.  When no answer comes, such as
after a connect timeout, it sends the request again, up to L</attempts> in
all, and then dies with "no response" and the transport error.  For an answer
of 400 or more it does not send again, and dies with the status and the
message.

=cut

sub get ( $self, $path ) {
    my $url = Mojo::URL->new( $self->api . $path );
    my $tx;
    retry $self->attempts, $self->retry_delay, sub { $tx = $self->ua->get($url) }, sub { !$tx->res->code };
    my $res = $tx->res;
    die "MetaCPAN GET $url: no response: " . ( $tx->error->{message} // 'unknown' ) . "\n" if !$res->code;
    if ( $res->code >= 400 ) {
        my $message = eval { $res->json->{message} } // $res->body;
        die sprintf( "MetaCPAN GET %s: %d %s\n", $url->path, $res->code, $message // q{} );
    }
    return $res->json;
}

=attr releases_of

The answers of L</releases>, by distribution.  Each object asks MetaCPAN once
for a distribution, and keeps the answer for its life.

=cut

has releases_of => sub { {} };

=method releases

C<($dist)>.  Each release of the distribution, newest first, as MetaCPAN
gives it: a hash reference with C<version>, C<author>, C<status> and more.
That includes a release that was deleted from CPAN and is on BackPAN only.  A
distribution that MetaCPAN does not know has none.  It asks once for each
distribution, as L</releases_of> says, and an error is not kept.

=cut

sub releases ( $self, $dist ) {
    return $self->releases_of->{$dist} //= $self->get( '/release/versions/' . Mojo::Util::url_escape($dist) )->{releases} // [];
}

=method versions

C<($dist)>.  The version of each of L</releases>, newest first.  It counts a
release that is on BackPAN only, because PAUSE never takes that version of
the distribution again.

=cut

sub versions ( $self, $dist ) {
    return [ map { $_->{version} } @{ $self->releases($dist) } ];
}

=method latest_author

C<($dist)>.  The PAUSE ID that uploaded the newest of L</releases>.  Undef
when the distribution has no release.

=cut

sub latest_author ( $self, $dist ) {
    my ($newest) = @{ $self->releases($dist) };
    return $newest ? $newest->{author} : undef;
}

1;

=head1 SYNOPSIS

    use 5.040;
    use App::BatchRelease::MetaCPAN;

    my $cpan     = App::BatchRelease::MetaCPAN->new( timeout => 30 );
    my $released = grep { $_ eq '0.006' } @{ $cpan->versions('App-BatchRelease') };

=head1 DESCRIPTION

A blocking client of the MetaCPAN API, which needs no token, over
L<Mojo::UserAgent>.  L<App::BatchRelease::State/release_state> takes any
object with a L</versions> method, so a caller that has its own client, such
as App::Clod, passes that one.  Each error message ends in a newline, so C<perl>
adds no file and line to it, and it can be shown as it is.

=cut
