package App::BatchRelease::Prereqs;

# ABSTRACT: Which distributions of a batch need which, and the order to release them in

use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';

use Config::INI::Reader();
use File::Find();
use Graph();
use Module::Metadata();
use Mojo::File();
use Perl::PrereqScanner();
use YAML::XS();
use Cpanel::JSON::XS();

=head1 SYNOPSIS

    use 5.040;
    use App::BatchRelease::Prereqs;

    my %dists = map {
        $_->[0] => {
            provides => App::BatchRelease::Prereqs::provides( $_->[1] ),
            requires => App::BatchRelease::Prereqs::requires( $_->[1] ),
        }
    } ( [ 'Foo-Bar' => '/bogus/Foo-Bar' ], [ 'Foo-Baz' => '/bogus/Foo-Baz' ] );
    my $plan = App::BatchRelease::Prereqs::order( \%dists );
    print "$_\n" for @{ $plan->{order} };

=head1 DESCRIPTION

A distribution that requires another of the same batch must reach CPAN after
it.  These functions find what each distribution requires and provides from
its checkout, without building it, and sort the batch.

Building would give the exact prerequisites, as C<[AutoPrereqs]> writes them
into the metadata.  But a build runs the plugins of the distribution, and a
dry run must not change a checkout.  So L</requires> reads the same sources
that the plugins read: the code, through L<Perl::PrereqScanner>, which
C<[AutoPrereqs]> runs too, the C<[Prereqs]> sections of F<dist.ini>, and
F<prereqs.yml> or F<prereqs.json>, which C<[PrereqsFile]> reads.  Every phase
counts, the tests too, because C<dzil release> runs the tests.

=cut

# The directories of a checkout whose files are code that a build ships.
our @CODE = qw{lib bin script t};

# Each file under the directories of @dirs in $root that $want accepts, as a path.
my sub files_under ( $root, $want, @dirs ) {
    my @found;
    my @existing = grep { -d } map { "$root/$_" } @dirs;
    return () if !@existing;
    File::Find::find( { no_chdir => 1, wanted => sub { push @found, $File::Find::name if !-d $File::Find::name && $want->($File::Find::name) } }, @existing );
    my @sorted = sort @found;
    return @sorted;
}

=func provides

C<($root)>.  The packages that the F<.pm> files under F<lib/> of the
checkout C<$root> declare, sorted, as an array reference.

=cut

sub provides ($root) {
    my %packages;
    for my $file ( files_under( $root, sub ($path) { $path =~ m{[.]pm\z} }, 'lib' ) ) {
        my $meta = Module::Metadata->new_from_file($file) // next;
        $packages{$_} = 1 for grep { $_ ne 'main' } $meta->packages_inside;
    }
    return [ sort keys %packages ];
}

=func requires

C<($root)>.  The modules that the distribution in the checkout C<$root>
requires, in any phase, sorted, as an array reference: what
L<Perl::PrereqScanner> finds in the files under F<lib/>, F<bin/>,
F<script/> and F<t/>, the keys of each section of F<dist.ini> whose name
starts with C<Prereqs>, and the modules of F<prereqs.yml> and
F<prereqs.json>.  It includes the modules that the distribution provides
itself, and C<perl>.  It dies when a file of prerequisites does not parse.

=cut

sub requires ($root) {
    my %modules;
    my $scanner = Perl::PrereqScanner->new;
    my $perl    = sub ($path) { $path =~ m{[.](?:pm|pl|t|psgi)\z} || $path =~ m{/(?:bin|script)/[^/.]+\z} };
    for my $file ( files_under( $root, $perl, @CODE ) ) {
        my $found = eval { $scanner->scan_file($file) } // die "Cannot read the prerequisites of $file: $@";
        $modules{$_} = 1 for $found->required_modules;
    }

    my $ini = Mojo::File->new( $root, 'dist.ini' );
    if ( -e $ini ) {
        my $config = Config::INI::Reader->read_file("$ini");
        for my $section ( grep { m{\APrereqs(?:\s|\z)} } keys %$config ) {
            $modules{$_} = 1 for grep { !m{\A-} } keys %{ $config->{$section} };
        }
    }

    for my $name (qw{prereqs.yml prereqs.json}) {
        my $file = Mojo::File->new( $root, $name );
        next if !-e $file;
        my $data = $name =~ m{[.]yml\z} ? YAML::XS::LoadFile("$file") : Cpanel::JSON::XS->new->decode( $file->slurp );
        for my $relations ( grep { ref eq 'HASH' } values %{ $data // {} } ) {
            for my $set ( grep { ref eq 'HASH' } values %$relations ) {
                $modules{$_} = 1 for keys %$set;
            }
        }
    }
    return [ sort keys %modules ];
}

=func order

C<(\%dists)>, a hash from the name of each distribution of the batch to a
hash reference of C<provides> and C<requires>, as L</provides> and
L</requires> return them.  Returns a hash reference of:

=over

=item C<order>

The names of the distributions that can be released, each after every
distribution of the batch that it requires.  The same batch gives the same
order on every run.

=item C<needs>

A hash from each name to the names of the other distributions of the batch
that it requires, sorted.

=item C<cycles>

A hash from the name of each distribution that requires itself through others
of the batch, to the names of the others of its cycle, sorted.

=item C<blocked>

A hash from the name of each distribution outside a cycle that requires one
in a cycle, directly or through others, to the names of the distributions of
the batch that it requires and that are not in C<order>, sorted.

=back

A distribution requires another when it requires a module that the other
provides.  When two of the batch provide one module, both count.

=cut

sub order ($dists) {
    my %provider;
    for my $name ( sort keys %$dists ) {
        push @{ $provider{$_} }, $name for @{ $dists->{$name}{provides} // [] };
    }
    my %needs;
    for my $name ( keys %$dists ) {
        my %on = map { $_ => 1 } grep { $_ ne $name } map { @{ $provider{$_} // [] } } @{ $dists->{$name}{requires} // [] };
        $needs{$name} = [ sort keys %on ];
    }

    # An edge from each distribution to each one that it requires.
    my $graph = Graph->new( directed => 1 );
    $graph->add_vertices( keys %$dists );
    for my $name ( keys %needs ) {
        for my $need ( @{ $needs{$name} } ) {
            $graph->add_edge( $name, $need );
        }
    }

    my %cycles;
    for my $component ( grep { @$_ > 1 } $graph->strongly_connected_components ) {
        for my $name (@$component) {
            $cycles{$name} = [ sort grep { $_ ne $name } @$component ];
        }
    }
    my @blocked = grep { !$cycles{$_} } $graph->all_predecessors( keys %cycles );

    my $free = $graph->copy;
    $free->delete_vertices( keys %cycles, @blocked );

    # The edges point at what a distribution requires, so the sort puts each
    # before it, and the reverse after.  next_alphabetic makes it repeatable.
    my @order   = reverse $free->topological_sort( next_alphabetic => 1 );
    my %done    = map { $_ => 1 } @order;
    my %blocked = map {
        my $name = $_;
        $name => [ grep { !$done{$_} } @{ $needs{$name} } ]
    } @blocked;
    return { order => \@order, needs => \%needs, cycles => \%cycles, blocked => \%blocked };
}

1;
