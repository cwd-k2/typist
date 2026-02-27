use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Hover on function ───────────────────────────

subtest 'hover returns function signature' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :Params(Int, Int) :Returns(Int) ($a, $b) { $a + $b }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on 'add'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/sub add/, 'contains function name';
    like $hover->{result}{contents}{value}, qr/Int/, 'contains type info';
};

# ── Hover on typedef ────────────────────────────

subtest 'hover returns typedef info' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 10 },  # on typedef line
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/type Age/, 'contains typedef';
};

# ── Hover on function call site ─────────────────

subtest 'hover on function call site' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :Params(Str) :Returns(Str) ($name) { "Hello, $name" }
sub add :Params(Int, Int) :Returns(Int) ($a, $b) { $a + $b }
say greet("Bob");
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 3, character => 5 },  # on 'greet' in call
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/sub greet/, 'resolves to greet, not add';
    unlike $hover->{result}{contents}{value}, qr/sub add/, 'does not show add';
};

# ── Hover distinguishes multiple functions ──────

subtest 'hover distinguishes between multiple functions' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :Params(Str) :Returns(Str) ($name) { "Hello, $name" }
sub add :Params(Int, Int) :Returns(Int) ($a, $b) { $a + $b }
my $result = add(1, 2);
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 3, character => 15 },  # on 'add' in call
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/sub add/, 'resolves to add';
    unlike $hover->{result}{contents}{value}, qr/sub greet/, 'does not show greet';
};

# ── Hover on newtype ──────────────────────────────

subtest 'hover returns newtype info' => sub {
    my $source = <<'PERL';
use v5.40;
newtype UserId => Int;
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 10 },  # on 'UserId'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/newtype UserId/, 'contains newtype';
};

# ── Hover on effect ──────────────────────────────

subtest 'hover returns effect info' => sub {
    my $source = <<'PERL';
use v5.40;
effect Console => {};
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 8 },  # on 'Console'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/effect Console/, 'contains effect';
};

# ── Hover on function with generics and effects ──

subtest 'hover shows generics and effects on function' => sub {
    my $source = <<'PERL';
use v5.40;
sub fetch :Generic(T) :Params(Str) :Returns(T) :Eff(Console) ($url) { }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on 'fetch'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/<T>/, 'contains generics';
    like $hover->{result}{contents}{value}, qr/!Eff\(Console\)/, 'contains effect annotation';
};

# ── Hover on unannotated function shows Eff(*) ──

subtest 'hover shows unannotated function as Any with Eff(*)' => sub {
    my $source = <<'PERL';
use v5.40;
sub helper ($x) { $x }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on 'helper'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/sub helper/, 'contains function name';
    like $hover->{result}{contents}{value}, qr/Any/, 'shows Any for params/returns';
    like $hover->{result}{contents}{value}, qr/!Eff\(\*\)/, 'shows !Eff(*) for unannotated';
};

# ── Hover on inferred variable type ──────────────

subtest 'hover shows inferred variable type' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :Params(Str) :Returns(Str) ($name) { "Hello, $name" }
my $result = greet("Alice");
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 5 },  # on '$result'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/\$result/, 'contains variable name';
    like $hover->{result}{contents}{value}, qr/Str/, 'shows inferred type Str';
};

done_testing;
