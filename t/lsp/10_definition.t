use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Definition of same-file function ──────────

subtest 'definition jumps to function declaration' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
my $result = add(1, 2);
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/definition', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 15 },  # on 'add' in call
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got definition response';
    ok $resp->{result}, 'has result';
    is $resp->{result}{uri}, 'file:///test.pm', 'same file URI';
    is $resp->{result}{range}{start}{line}, 1, 'points to declaration line';
};

# ── Definition of typedef ────────────────────

subtest 'definition jumps to typedef' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
sub get_age :sig(( ) -> Age) () { 42 }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/definition', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 10 },  # on 'Age' in typedef line
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got definition response';
    ok $resp->{result}, 'has result';
    is $resp->{result}{range}{start}{line}, 1, 'points to typedef line';
};

# ── No definition for unknown word ──────────

subtest 'definition returns null for unknown symbol' => sub {
    my $source = <<'PERL';
use v5.40;
say "hello";
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/definition', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on "hello"
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got definition response';
    ok !$resp->{result}, 'result is null for unknown symbol';
};

# ── Definition for cross-package constructor via workspace ──

subtest 'definition jumps to datatype constructor across files' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Server;
    require Typist::LSP::Transport;
    require Typist::LSP::Logger;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Types.pm" or die;
    print $fh <<'PERL';
package Types;
use v5.40;
newtype UserId => 'Int';
datatype Result =>
    Ok  => '(Int)',
    Err => '(Str)';
1;
PERL
    close $fh;

    my $server = Typist::LSP::Server->new(
        transport => Typist::LSP::Transport->new,
        logger    => Typist::LSP::Logger->new(level => 'off'),
    );
    $server->_handle_initialize(+{ rootUri => "file://$dir" });

    my $source = <<'PERL';
package Consumer;
use v5.40;
use Types;
my $val = Ok(42);
my $uid = UserId(1);
PERL
    $server->_handle_did_open(+{
        textDocument => +{ uri => 'file:///consumer.pm', text => $source, version => 1 },
    });

    # Go-to-definition on Ok → should jump to Types.pm datatype line
    my $result1 = $server->_handle_definition(+{
        textDocument => +{ uri => 'file:///consumer.pm' },
        position     => +{ line => 3, character => 10 },
    });
    ok $result1, 'definition found for Ok constructor';
    like $result1->{uri}, qr/Types\.pm/, 'jumps to Types.pm';
    is $result1->{range}{start}{line}, 3, 'points to datatype declaration line';

    # Go-to-definition on UserId → should jump to Types.pm newtype line
    my $result2 = $server->_handle_definition(+{
        textDocument => +{ uri => 'file:///consumer.pm' },
        position     => +{ line => 4, character => 10 },
    });
    ok $result2, 'definition found for UserId constructor';
    like $result2->{uri}, qr/Types\.pm/, 'jumps to Types.pm';
    is $result2->{range}{start}{line}, 2, 'points to newtype declaration line';
};

# ── Definition for effect operation (same file) ──────

subtest 'definition jumps to effect from qualified op' => sub {
    my $source = <<'PERL';
use v5.40;
effect Console => +{ writeLine => '(Str) -> Void' };
sub run :sig(() -> Void ![Console]) () {
    Console::writeLine("hello");
}
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/definition', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 3, character => 5 },  # on 'Console' in Console::writeLine
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got definition response';
    ok $resp->{result}, 'has result';
    is $resp->{result}{uri}, 'file:///test.pm', 'same file URI';
    is $resp->{result}{range}{start}{line}, 1, 'points to effect declaration line';
};

# ── Definition for struct field accessor (same file) ─

subtest 'definition jumps to struct from field accessor' => sub {
    my $source = <<'PERL';
use v5.40;
struct Point => (x => 'Int', y => 'Int');
sub make :sig(() -> Point) () {
    my $p :sig(Point) = Point(x => 1, y => 2);
    $p->x;
}
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/definition', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 4, character => 8 },  # on 'x' in $p->x
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got definition response';
    ok $resp->{result}, 'has result';
    is $resp->{result}{uri}, 'file:///test.pm', 'same file URI';
    is $resp->{result}{range}{start}{line}, 1, 'points to struct declaration line';
};

# ── Definition for effect op (cross-file) ──────────

subtest 'definition jumps to effect across files' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Server;
    require Typist::LSP::Transport;
    require Typist::LSP::Logger;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Effects.pm" or die;
    print $fh <<'PERL';
package Effects;
use v5.40;
effect Logger => +{ log => '(Str) -> Void' };
1;
PERL
    close $fh;

    my $server = Typist::LSP::Server->new(
        transport => Typist::LSP::Transport->new,
        logger    => Typist::LSP::Logger->new(level => 'off'),
    );
    $server->_handle_initialize(+{ rootUri => "file://$dir" });

    my $source = <<'PERL';
package Consumer;
use v5.40;
Logger::log("hello");
PERL
    $server->_handle_did_open(+{
        textDocument => +{ uri => 'file:///consumer.pm', text => $source, version => 1 },
    });

    my $result = $server->_handle_definition(+{
        textDocument => +{ uri => 'file:///consumer.pm' },
        position     => +{ line => 2, character => 3 },  # on 'Logger' in Logger::log
    });
    ok $result, 'definition found for Logger effect';
    like $result->{uri}, qr/Effects\.pm/, 'jumps to Effects.pm';
};

done_testing;
