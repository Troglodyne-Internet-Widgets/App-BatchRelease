#!perl
use 5.040;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use Test::MockModule;
use File::Temp();
use Mojo::File();
use FindBin::libs;

use App::BatchRelease::Prereqs();

# A checkout with these files, by path, in a directory that the test removes.
sub checkout (%files) {
    my $dir = File::Temp->newdir;
    for my $path ( keys %files ) {
        my $file = Mojo::File->new( $dir, $path );
        $file->dirname->make_path;
        $file->spew( $files{$path} );
    }
    return $dir;
}

subtest provides => sub {
    my $dir = checkout(
        'lib/Test/Dist.pm'        => "package Test::Dist;\npackage Test::Dist::Inner;\n1;\n",
        'lib/Test/Dist/Helper.pm' => "package Test::Dist::Helper 0.001;\n1;\n",
        'lib/Test/Dist/notes.txt' => "package Not::Perl;\n",
        't/Test-Dist.t'           => "package Test::Only;\n",
    );
    is( App::BatchRelease::Prereqs::provides("$dir"),                                [qw{Test::Dist Test::Dist::Helper Test::Dist::Inner}], 'every package of every .pm under lib/, and nothing from other files or directories' );
    is( App::BatchRelease::Prereqs::provides( checkout( 'README' => "x\n" ) . q{} ), [],                                                    'no lib/, nothing provided' );
};

subtest requires => sub {
    my $dir = checkout(
        'lib/Test/Dist.pm' => "package Test::Dist;\nuse 5.040;\nuse Test::Other::Module ();\nrequire Test::Lazy;\n1;\n",
        'script/test-dist' => "#!perl\nuse Test::From::Script;\n",
        't/basic.t'        => "use Test::From::Test;\n",
        'xt/author.t'      => "use Test::Not::Scanned;\n",
        'dist.ini'         => "name = Test-Dist\n[Prereqs]\nTest::From::Ini = 1\n[Prereqs / TestRequires]\n-phase = test\nTest::From::Ini::Test = 0\n[MetaResources]\nTest::Not::Prereq = 1\n",
        'prereqs.yml'      => "runtime:\n  requires:\n    perl: '5.040'\n    Test::From::Yaml: '1'\ntest:\n  recommends:\n    Test::From::Yaml::Test: '0'\n",
        'prereqs.json'     => '{"develop":{"requires":{"Test::From::Json":"0"}}}',
    );
    is(
        App::BatchRelease::Prereqs::requires("$dir"),
        [qw{Test::From::Ini Test::From::Ini::Test Test::From::Json Test::From::Script Test::From::Test Test::From::Yaml Test::From::Yaml::Test Test::Lazy Test::Other::Module perl}],
        'the code under lib/, script/ and t/, the [Prereqs] sections of dist.ini without their - keys, and prereqs.yml and prereqs.json, in every phase; not xt/ and not other sections'
    );
    like( dies { App::BatchRelease::Prereqs::requires( checkout( 'prereqs.yml' => "runtime: [\n" ) . q{} ) }, qr{YAML}i, 'a prereqs.yml that does not parse dies' );

    my $scanner = Test::MockModule->new('Perl::PrereqScanner')->redefine( scan_file => sub ( $self, $file ) { die "PPI parse failed\n" } );
    my $broken  = checkout( 'lib/Test/Broken.pm' => "package Test::Broken;\n" );
    is( dies { App::BatchRelease::Prereqs::requires("$broken") }, "Cannot read the prerequisites of $broken/lib/Test/Broken.pm: PPI parse failed\n", 'a file that cannot be scanned dies, naming it, rather than leave out what it requires' );
};

subtest order => sub {
    my %dists = (
        'Test-App'  => { provides => ['Test::App'],  requires => [qw{Test::Base Test::Util perl}] },
        'Test-Util' => { provides => ['Test::Util'], requires => [qw{Test::Base Test::Util}] },
        'Test-Base' => { provides => ['Test::Base'], requires => ['strict'] },
        'Test-Free' => { provides => ['Test::Free'], requires => [] },
    );
    my $plan = App::BatchRelease::Prereqs::order( \%dists );
    is( $plan->{order},  [qw{Test-Base Test-Free Test-Util Test-App}],                                                                    'each after what it requires, and by name among those free to go' );
    is( $plan->{needs},  { 'Test-App' => [qw{Test-Base Test-Util}], 'Test-Util' => ['Test-Base'], 'Test-Base' => [], 'Test-Free' => [] }, 'what each requires of the batch; a module it provides itself does not count' );
    is( $plan->{cycles}, {},                                                                                                              'no cycle' );

    my %cycle = (
        'Test-One'   => { provides => ['Test::One'],   requires => ['Test::Two'] },
        'Test-Two'   => { provides => ['Test::Two'],   requires => ['Test::One'] },
        'Test-Three' => { provides => ['Test::Three'], requires => ['Test::Two'] },
        'Test-Four'  => { provides => ['Test::Four'],  requires => [] },
    );
    $plan = App::BatchRelease::Prereqs::order( \%cycle );
    is( $plan->{order},  ['Test-Four'],                                                                            'only what is outside the cycle and does not depend on it' );
    is( $plan->{cycles}, { 'Test-One' => ['Test-Two'], 'Test-Two' => ['Test-One'], 'Test-Three' => ['Test-Two'] }, 'the cycle, and what depends on it, with the requirements that hold each back' );
};

done_testing;
