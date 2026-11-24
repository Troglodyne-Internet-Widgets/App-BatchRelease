#!perl
use 5.040;
no autovivification;
use warnings FATAL => 'all';
use re '/aasx';
use Test2::V0;
use Test2::Plugin::NoWarnings;
use Test::MockModule;
use File::Temp();
use FindBin::libs;

use App::BatchRelease::Prompt();

subtest ask => sub {
    my ( %got, $redirected );
    my $prompter = Test::MockModule->new('IO::Prompter')->redefine(
        prompt => sub ( $message, %options ) {
            %got = ( message => $message, options => \%options, argv => "${\ *ARGV}", args => [@ARGV] );
            return 'answer';
        }
    );
    my $prompt = Test::MockModule->new('App::BatchRelease::Prompt')->redefine( output_is_redirected => sub () { return $redirected } );

    local @ARGV = qw{/bogus/one /bogus/two};
    $redirected = 0;
    is( App::BatchRelease::Prompt::ask( 'Go on?', -echo => '*' ), 'answer',         'the answer of IO::Prompter' );
    is( $got{options},                                            { -echo => '*' }, 'the options go to IO::Prompter unchanged' );
    isnt( $got{argv}, '*main::ARGV', 'the prompt does not see the *ARGV of the program, so it does not try to open its arguments' );
    is( \@ARGV, [qw{/bogus/one /bogus/two}], 'and @ARGV is the same again after the call' );

    my $tty = File::Temp->new;
    local $App::BatchRelease::Prompt::TERMINAL = $tty->filename;
    $redirected = 1;
    App::BatchRelease::Prompt::ask('Go on?');
    is( ref $got{options}{-out}, 'GLOB', 'with the output redirected, the question goes to the terminal' );
    App::BatchRelease::Prompt::ask( 'Go on?', -out => 'mine' );
    is( $got{options}{-out}, 'mine', 'unless the caller says where' );
};

subtest at_terminal => sub {
    my $tty = File::Temp->new;
    local $App::BatchRelease::Prompt::TERMINAL = $tty->filename;
    my %at = App::BatchRelease::Prompt::at_terminal('the thing');
    is( [ sort keys %at ], [qw{-in -out}], 'both ends at the terminal' );
    local $App::BatchRelease::Prompt::TERMINAL = '/bogus/tty';
    my $want  = 'Cannot ask for the thing at a terminal: /bogus/tty:';
    my $error = dies { App::BatchRelease::Prompt::at_terminal('the thing') };
    is( substr( $error, 0, length $want ), $want, 'no terminal dies, naming what was to be asked' );
};

subtest answers_from => sub {
    my $tty = File::Temp->new;
    local $App::BatchRelease::Prompt::TERMINAL = $tty->filename;
    is( App::BatchRelease::Prompt::answers_from(), $tty->filename, 'the terminal, when it opens' );
    local $App::BatchRelease::Prompt::TERMINAL = '/bogus/tty';
    is( App::BatchRelease::Prompt::answers_from(), '/dev/null', 'else /dev/null, where a question takes its default' );
};

done_testing;
