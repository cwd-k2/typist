use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Hover on function ───────────────────────────

subtest 'hover returns function signature' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
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
    like $hover->{result}{contents}{value}, qr/sub add\(Int, Int\) -> Int/, 'shows sub add(Int, Int) -> Int';
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
sub greet :Type((Str) -> Str) ($name) { "Hello, $name" }
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
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
sub greet :Type((Str) -> Str) ($name) { "Hello, $name" }
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
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
sub fetch :Type(<T>(Str) -> T !Eff(Console)) ($url) { }
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
    like $hover->{result}{contents}{value}, qr/sub fetch<T>\(Str\) -> T !Eff\(Console\)/, 'shows sub fetch<T>(Str) -> T !Eff(Console)';
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
sub greet :Type((Str) -> Str) ($name) { "Hello, $name" }
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
    like $hover->{result}{contents}{value}, qr/\$result: Str \(inferred\)/, 'shows inferred type with flag';
};

# ── Hover on typeclass with superclass ──────────

subtest 'hover shows typeclass with var_spec and methods' => sub {
    my $source = <<'PERL';
use v5.40;
typeclass Ord => 'T: Eq', +{
    compare => '(T, T) -> Int',
};
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 12 },  # on 'Ord'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/typeclass Ord/, 'contains typeclass name';
    like $hover->{result}{contents}{value}, qr/T: Eq/, 'contains superclass constraint';
    like $hover->{result}{contents}{value}, qr/compare/, 'contains method name';
};

# ── Hover on function parameter ───────────────

subtest 'hover shows parameter type inside function' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 12 },  # on '$a' in return
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/\$a: Int/, 'shows $a as Int';
    like $hover->{result}{contents}{value}, qr/parameter of add/, 'shows parameter of add';
};

# ── Hover on Perl builtin function ──────────────

subtest 'hover shows builtin function as Any with Eff(*)' => sub {
    my $source = <<'PERL';
use v5.40;
say "hello";
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 1 },  # on 'say'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/sub say\(Any\.\.\.\) -> Any !Eff\(\*\)/, 'shows sub say(Any...) -> Any !Eff(*)';
};

# ── Hover on declared builtin ───────────────────

subtest 'hover shows declared builtin with specific type' => sub {
    my $source = <<'PERL';
use v5.40;
declare say => '(Str) -> Void !Eff(Console)';
say "hello";
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 1 },  # on 'say'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/sub say\(Str\) -> Void/, 'shows declared type';
    like $hover->{result}{contents}{value}, qr/!Eff\(Console\)/, 'shows Console effect';
    like $hover->{result}{contents}{value}, qr/declared/, 'shows declared label';
};

# ── Hover on datatype ─────────────────────────────

subtest 'hover shows datatype info' => sub {
    my $source = <<'PERL';
use v5.40;
datatype Shape =>
    Circle    => '(Int)',
    Rectangle => '(Int, Int)';
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 10 },  # on 'Shape'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/datatype Shape/, 'contains datatype name';
    like $hover->{result}{contents}{value}, qr/Circle/, 'shows Circle variant';
};

# ── Hover on ADT constructor ──────────────────────

subtest 'hover shows constructor signature' => sub {
    my $source = <<'PERL';
use v5.40;
datatype Shape =>
    Circle    => '(Int)',
    Rectangle => '(Int, Int)';
my $c = Circle(5);
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 4, character => 9 },  # on 'Circle' in call
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/sub Circle\(Int\) -> Shape/, 'shows sub Circle(Int) -> Shape';
};

# ── Hover on typeclass method ──────────────────────

subtest 'hover shows typeclass method signature' => sub {
    my $source = <<'PERL';
use v5.40;
typeclass Show => 'T', +{
    show => '(T) -> Str',
};
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 5 },  # on 'show'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/sub show/, 'shows function name';
    like $hover->{result}{contents}{value}, qr/T/, 'shows type variable T';
    like $hover->{result}{contents}{value}, qr/-> Str/, 'shows return type Str';
};

done_testing;
