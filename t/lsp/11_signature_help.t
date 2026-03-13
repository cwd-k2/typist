use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Signature help on first parameter ──────────

subtest 'signatureHelp shows function signature at open paren' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
add(
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/signatureHelp', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 4 },  # after 'add('
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got signatureHelp response';
    ok $resp->{result}, 'has result';
    my $sigs = $resp->{result}{signatures};
    ok $sigs && @$sigs, 'has signatures';
    like $sigs->[0]{label}, qr/add\(Int, Int\) -> Int/, 'label shows full signature';
    is scalar @{$sigs->[0]{parameters}}, 2, 'two parameters';
    is $resp->{result}{activeParameter}, 0, 'active parameter is 0 (first)';
};

# ── Signature help on second parameter ──────────

subtest 'signatureHelp highlights second parameter after comma' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
add(1,
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/signatureHelp', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 6 },  # after 'add(1, '
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got signatureHelp response';
    is $resp->{result}{activeParameter}, 1, 'active parameter is 1 (second)';
};

# ── Signature help returns null for non-function ─

subtest 'signatureHelp returns null outside function call' => sub {
    my $source = <<'PERL';
use v5.40;
my $x = 42;
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/signatureHelp', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 10 },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got signatureHelp response';
    ok !$resp->{result}, 'result is null outside function call';
};

# ── Signature help on multi-line call ─────────────

subtest 'signatureHelp works across multiple lines' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :sig((Str, Int, Str) -> Str) ($name, $age, $city) { "$name ($age) from $city" }
greet(
    "Alice",
    30,

PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/signatureHelp', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 5, character => 4 },  # blank line after '30,' — waiting for 3rd arg
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got signatureHelp response';
    ok $resp->{result}, 'has result for multi-line call';
    my $sigs = $resp->{result}{signatures};
    ok $sigs && @$sigs, 'has signatures';
    like $sigs->[0]{label}, qr/greet\(Str, Int, Str\)/, 'label shows full signature';
    is $resp->{result}{activeParameter}, 2, 'active parameter is 2 (third)';
};

# ── Signature help for cross-package constructor ──

subtest 'signatureHelp resolves imported constructor via workspace' => sub {
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

    # Build server with workspace
    my $server = Typist::LSP::Server->new(
        transport => Typist::LSP::Transport->new,
        logger    => Typist::LSP::Logger->new(level => 'off'),
    );
    $server->_handle_initialize(+{ rootUri => "file://$dir" });

    # Open a consumer file
    my $source = <<'PERL';
package Consumer;
use v5.40;
use Types;
my $val = Ok(42);
my $uid = UserId(
PERL
    $server->_handle_did_open(+{
        textDocument => +{ uri => 'file:///consumer.pm', text => $source, version => 1 },
    });

    # SignatureHelp on Ok(
    my $result1 = $server->_handle_signature_help(+{
        textDocument => +{ uri => 'file:///consumer.pm' },
        position     => +{ line => 3, character => 14 },
    });
    ok $result1, 'signatureHelp for cross-package Ok';
    ok $result1->{signatures} && @{$result1->{signatures}}, 'has signatures';
    like $result1->{signatures}[0]{label}, qr/Ok\(Int\)/, 'label shows Ok(Int)';

    # SignatureHelp on UserId(
    my $result2 = $server->_handle_signature_help(+{
        textDocument => +{ uri => 'file:///consumer.pm' },
        position     => +{ line => 4, character => 17 },
    });
    ok $result2, 'signatureHelp for cross-package UserId';
    like $result2->{signatures}[0]{label}, qr/UserId\(Int\)/, 'label shows UserId(Int)';
};

# ── Signature help includes effect expression ────

subtest 'signatureHelp shows effect in label' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :sig((Str) -> Void ![Console]) ($name) { say $name }
greet(
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/signatureHelp', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 6 },  # after 'greet('
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got signatureHelp response';
    ok $resp->{result}, 'has result';
    my $sigs = $resp->{result}{signatures};
    ok $sigs && @$sigs, 'has signatures';
    like $sigs->[0]{label}, qr/greet\(Str\) -> Void/, 'label shows params and return';
    like $sigs->[0]{label}, qr/!\[Console\]/, 'label includes effect expression';
};

# ── Signature help for struct constructor ──────────

subtest 'signatureHelp shows struct field parameters' => sub {
    require Typist::LSP::Workspace;
    require Typist::LSP::Server;
    require Typist::LSP::Transport;
    require Typist::LSP::Logger;

    my $ws = Typist::LSP::Workspace->new;
    my $type_source = <<'PERL';
use v5.40;
package Types;
struct Point => (x => 'Int', y => 'Int');
PERL
    $ws->update_file('/fake/Types.pm', $type_source);

    my $server = Typist::LSP::Server->new(
        transport => Typist::LSP::Transport->new,
        logger    => Typist::LSP::Logger->new(level => 'off'),
    );
    # Manually set workspace
    $server->{workspace} = $ws;

    my $source = <<'PERL';
use v5.40;
Point(
PERL
    $server->_handle_did_open(+{
        textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
    });

    my $result = $server->_handle_signature_help(+{
        textDocument => +{ uri => 'file:///test.pm' },
        position     => +{ line => 1, character => 6 },
    });
    ok $result, 'signatureHelp for struct constructor';
    my $sigs = $result->{signatures};
    ok $sigs && @$sigs, 'has signatures';
    like $sigs->[0]{label}, qr/Point\(/, 'label starts with Point(';
    like $sigs->[0]{label}, qr/x => Int/, 'label includes x => Int';
    like $sigs->[0]{label}, qr/y => Int/, 'label includes y => Int';
};

# ── Signature help for method call ─────────────────

subtest 'signatureHelp context detects qualified function call' => sub {
    use Typist::LSP::Document;

    my $source = <<'PERL';
use v5.40;
my $p :sig(Point) = Point(x => 1, y => 2);
Point::derive($p,
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///test_method.pm', content => $source);
    my $ctx = $doc->signature_context(2, length('Point::derive($p,'));
    ok $ctx, 'got signature context for qualified call';
    is $ctx->{name}, 'derive', 'function name is derive';
};

subtest 'signatureHelp context detects effect qualified call' => sub {
    use Typist::LSP::Document;

    my $source = <<'PERL';
use v5.40;
Logger::log("info",
PERL

    my $doc = Typist::LSP::Document->new(uri => 'file:///test_eff_sig.pm', content => $source);
    my $ctx = $doc->signature_context(1, length('Logger::log("info",'));
    ok $ctx, 'got signature context for effect op call';
    is $ctx->{name}, 'log', 'function name is log';
    is $ctx->{qualifier}, 'Logger', 'qualifier is Logger (effect name)';
    is $ctx->{active_parameter}, 1, 'active param is 1 (second arg)';
};

done_testing;
