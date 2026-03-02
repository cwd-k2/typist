use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Hover on function ───────────────────────────

subtest 'hover returns function signature' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
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
sub greet :sig((Str) -> Str) ($name) { "Hello, $name" }
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
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
sub greet :sig((Str) -> Str) ($name) { "Hello, $name" }
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
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
sub fetch :sig(<T>(Str) -> T ![Console]) ($url) { }
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
    like $hover->{result}{contents}{value}, qr/sub fetch<T>\(Str\) -> T !\[Console\]/, 'shows sub fetch<T>(Str) -> T ![Console]';
};

# ── Hover on unannotated function shows [*] ──

subtest 'hover shows unannotated function as Any with [*]' => sub {
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
    like $hover->{result}{contents}{value}, qr/!\[\*\]/, 'shows ![*] for unannotated';
};

# ── Hover on inferred variable type ──────────────

subtest 'hover shows inferred variable type' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :sig((Str) -> Str) ($name) { "Hello, $name" }
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
    like $hover->{result}{contents}{value}, qr/\$result: Str/, 'shows variable type';
    like $hover->{result}{contents}{value}, qr/\*inferred\*/, 'shows inferred annotation';
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
sub add :sig((Int, Int) -> Int) ($a, $b) {
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
    like $hover->{result}{contents}{value}, qr/parameter of.*add/, 'shows parameter of add';
};

# ── Hover on Perl builtin function ──────────────

subtest 'hover shows builtin function with Prelude signature' => sub {
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
    like $hover->{result}{contents}{value}, qr/sub say/, 'shows sub say';
    like $hover->{result}{contents}{value}, qr/-> Bool/, 'shows return type Bool (from Prelude)';
    like $hover->{result}{contents}{value}, qr/!\[IO\]/, 'shows ![IO] (from Prelude)';
};

# ── Hover on declared builtin ───────────────────

subtest 'hover shows declared builtin with specific type' => sub {
    my $source = <<'PERL';
use v5.40;
declare say => '(Str) -> Void ![Console]';
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
    like $hover->{result}{contents}{value}, qr/!\[Console\]/, 'shows Console effect';
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

# ── Hover on cross-package imported constructor ──

subtest 'hover resolves cross-package bare constructor via workspace' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    # Types package with exported constructors
    open my $fh1, '>', "$dir/lib/Types.pm" or die;
    print $fh1 <<'PERL';
package Types;
use v5.40;
newtype UserId => 'Int';
datatype Result =>
    Ok  => '(Int)',
    Err => '(Str)';
1;
PERL
    close $fh1;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    # Simulate a file that uses bare Ok(...) constructor
    my $source = <<'PERL';
package Consumer;
use v5.40;
use Types;
my $val = Ok(42);
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///test.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'Ok' at line 3, col ~10
    my $sym = $doc->symbol_at(3, 10);
    ok $sym, 'found symbol for bare Ok constructor';
    is $sym->{kind}, 'function', 'Ok is a function';
    like join(', ', ($sym->{params_expr} // [])->@*), qr/Int/, 'Ok param is Int';
    like $sym->{returns_expr} // '', qr/Result/, 'Ok returns Result';

    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'hover response for cross-package constructor';
    like $hover->{contents}{value}, qr/sub Ok/, 'hover shows sub Ok';

    # Hover on 'UserId' — should resolve as newtype constructor
    my $source2 = <<'PERL';
package Consumer;
use v5.40;
use Types;
my $uid = UserId(42);
PERL
    my $doc2 = Typist::LSP::Document->new(
        uri     => 'file:///test2.pm',
        content => $source2,
        version => 1,
    );
    $doc2->analyze(workspace_registry => $ws->registry);

    my $sym2 = $doc2->symbol_at(3, 10);
    ok $sym2, 'found symbol for bare UserId constructor';
    is $sym2->{kind}, 'function', 'UserId is a function';
    like $sym2->{returns_expr} // '', qr/UserId/, 'UserId returns UserId';
};

# ── Hover on qualified name: no hover on package part ──

subtest 'hover on package part of qualified call returns null' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib/Util");

    open my $fh, '>', "$dir/lib/Util/Math.pm" or die;
    print $fh <<'PERL';
package Util::Math;
use v5.40;
use Typist;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Util::Math;
my $x = Util::Math::add(1, 2);
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'add' part (after Util::Math::)
    # Line 3: "my $x = Util::Math::add(1, 2);"
    #          0123456789012345678901234
    #                                ^^ add starts at col 20
    my $sym_func = $doc->symbol_at(3, 21);  # on 'add'
    ok $sym_func, 'found symbol on function name part';
    is $sym_func->{kind}, 'function', 'resolved as function';

    # Hover on 'Util' part
    my $sym_pkg = $doc->symbol_at(3, 9);  # on 'Util'
    ok !$sym_pkg, 'no hover on package name part';

    # Hover on 'Math' part (still in package portion)
    my $sym_mid = $doc->symbol_at(3, 15);  # on 'Math'
    ok !$sym_mid, 'no hover on middle package segment';
};

# ── Hover on effect with operations ──────────────

subtest 'hover shows effect with operation signatures' => sub {
    my $source = <<'PERL';
use v5.40;
effect Console => +{
    readLine  => '() -> Str',
    writeLine => '(Str) -> Void',
};
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
    my $value = $hover->{result}{contents}{value};
    like $value, qr/effect Console/, 'contains effect name';
    like $value, qr/readLine/, 'shows readLine operation';
    like $value, qr/writeLine/, 'shows writeLine operation';
    like $value, qr/\(\) -> Str/, 'shows readLine signature';
    like $value, qr/\(Str\) -> Void/, 'shows writeLine signature';
};

# ── Hover on struct multi-line ───────────────────

subtest 'hover shows struct with multi-line fields' => sub {
    require Typist::LSP::Hover;

    # Directly test the Hover formatter with a struct symbol
    my $sym = +{
        kind   => 'struct',
        name   => 'Person',
        fields => ['age: Int', 'email: Str (optional)', 'name: Str'],
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover response';
    my $value = $hover->{contents}{value};
    like $value, qr/struct Person \{/, 'contains struct header with brace';
    like $value, qr/\n\s+age: Int/, 'age field on its own line';
    like $value, qr/\n\s+name: Str/, 'name field on its own line';
    like $value, qr/\n\s+email: Str/, 'email field on its own line';
};

# ── Hover on typeclass with method signatures ────

subtest 'hover shows typeclass with method signatures' => sub {
    my $source = <<'PERL';
use v5.40;
typeclass Eq => 'T', +{
    eq  => '(T, T) -> Bool',
    neq => '(T, T) -> Bool',
};
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 12 },  # on 'Eq'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    my $value = $hover->{result}{contents}{value};
    like $value, qr/typeclass Eq/, 'contains typeclass name';
    like $value, qr/eq:.*\(T, T\) -> Bool/, 'shows eq method with signature';
    like $value, qr/neq:.*\(T, T\) -> Bool/, 'shows neq method with signature';
};

# ── Hover on datatype multi-line variants ────────

subtest 'hover shows datatype with multi-line variants' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind => 'datatype',
        name => 'Shape',
        type => 'Circle(Int) | Point | Rectangle(Int, Int)',
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover response';
    my $value = $hover->{contents}{value};
    like $value, qr/datatype Shape/, 'contains datatype header';
    like $value, qr/= Circle\(Int\)/, 'first variant with =';
    like $value, qr/\| Point/, 'second variant with |';
    like $value, qr/\| Rectangle\(Int, Int\)/, 'third variant with |';
};

# ── Hover declared function note outside code block ──

subtest 'hover shows declared as italic note' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind         => 'function',
        name         => 'say',
        params_expr  => ['Str'],
        returns_expr => 'Void',
        eff_expr     => '[Console]',
        declared     => 1,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover response';
    my $value = $hover->{contents}{value};
    like $value, qr/```\n\n\*declared\*/, 'declared shown as italic note after code block';
};

# ── Hover on struct accessor ──────────────────────

subtest 'hover shows struct field type for simple accessor' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Models.pm" or die;
    print $fh <<'PERL';
package Models;
use v5.40;
use Typist;
struct Customer => (name => Str, tier => Str);
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Models;
sub show_tier :sig((Customer) -> Str) ($customer) {
    $customer->tier;
}
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'tier' at line 5: "    $customer->tier;"
    #                              0123456789012345678
    my $sym = $doc->symbol_at(5, 16);
    ok $sym, 'found symbol for accessor';
    is $sym->{kind}, 'field', 'kind is field';
    is $sym->{name}, 'tier', 'field name is tier';
    is $sym->{type}, 'Str', 'field type is Str';
    is $sym->{struct_name}, 'Customer', 'struct name is Customer';
    ok !$sym->{optional}, 'field is not optional';

    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'hover response for accessor';
    like $hover->{contents}{value}, qr/\(Customer\) tier: Str/, 'shows (Customer) tier: Str';
};

# ── Hover on chained accessor ────────────────────

subtest 'hover shows struct field type for chained accessor' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Shop.pm" or die;
    print $fh <<'PERL';
package Shop;
use v5.40;
use Typist;
struct Product => (name => Str, price => Int);
struct Order   => (product => Product, quantity => Int);
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Shop;
sub product_name :sig((Order) -> Str) ($order) {
    $order->product->name;
}
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'name' at line 5: "    $order->product->name;"
    #                              0123456789012345678901234
    my $sym = $doc->symbol_at(5, 24);
    ok $sym, 'found symbol for chained accessor';
    is $sym->{kind}, 'field', 'kind is field';
    is $sym->{name}, 'name', 'field name is name';
    is $sym->{type}, 'Str', 'field type is Str';
    is $sym->{struct_name}, 'Product', 'struct name is Product (from chain)';
};

# ── Hover on optional struct field accessor ──────

subtest 'hover shows optional struct field type' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Contact.pm" or die;
    print $fh <<'PERL';
package Contact;
use v5.40;
use Typist;
struct Customer => (name => Str, phone => optional(Str));
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Contact;
sub get_phone :sig((Customer) -> Str | Undef) ($c) {
    $c->phone;
}
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'phone' at line 5: "    $c->phone;"
    #                               01234567890
    my $sym = $doc->symbol_at(5, 8);
    ok $sym, 'found symbol for optional accessor';
    is $sym->{kind}, 'field', 'kind is field';
    is $sym->{name}, 'phone', 'field name is phone';
    ok $sym->{optional}, 'field is optional';

    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'hover response for optional accessor';
    like $hover->{contents}{value}, qr/\(Customer\) phone\?: Str/, 'shows (Customer) phone?: Str';
};

# ── Hover on function call return accessor ───────

subtest 'hover shows field type for function()->accessor' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Models.pm" or die;
    print $fh <<'PERL';
package Models;
use v5.40;
use Typist;
struct Customer => (name => Str, tier => Str);
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Models;
sub find_customer :sig((Int) -> Customer) ($id) { }
my $t = find_customer(1)->tier;
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'tier' at line 5: "my $t = find_customer(1)->tier;"
    #                              01234567890123456789012345678
    my $sym = $doc->symbol_at(5, 27);
    ok $sym, 'found symbol for func()->field accessor';
    is $sym->{kind}, 'field', 'kind is field';
    is $sym->{name}, 'tier', 'field name is tier';
    is $sym->{type}, 'Str', 'field type is Str';
    is $sym->{struct_name}, 'Customer', 'struct name is Customer';

    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'hover response';
    like $hover->{contents}{value}, qr/\(Customer\) tier: Str/, 'shows (Customer) tier: Str';
};

# ── Hover on cross-package function call accessor ──

subtest 'hover shows field type for Pkg::func()->accessor' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Repo.pm" or die;
    print $fh <<'PERL';
package Repo;
use v5.40;
use Typist;
struct Product => (name => Str, price => Int);
sub find :sig((Int) -> Product) ($id) { }
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Repo;
my $n = Repo::find(1)->name;
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'name' at line 4: "my $n = Repo::find(1)->name;"
    #                              0123456789012345678901234567
    my $sym = $doc->symbol_at(4, 24);
    ok $sym, 'found symbol for Pkg::func()->field';
    is $sym->{kind}, 'field', 'kind is field';
    is $sym->{name}, 'name', 'field name is name';
    is $sym->{type}, 'Str', 'field type is Str';
    is $sym->{struct_name}, 'Product', 'struct name is Product';
};

# ── Hover on chained function call accessor ──────

subtest 'hover shows field type for func()->f1->f2 chain' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Store.pm" or die;
    print $fh <<'PERL';
package Store;
use v5.40;
use Typist;
struct Product => (name => Str, price => Int);
struct Order   => (product => Product, qty => Int);
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Store;
sub get_order :sig((Int) -> Order) ($id) { }
my $n = get_order(1)->product->name;
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'name' at line 5: "my $n = get_order(1)->product->name;"
    #                              0         1         2         3
    #                              0123456789012345678901234567890123456
    my $sym = $doc->symbol_at(5, 32);
    ok $sym, 'found symbol for func()->f1->f2';
    is $sym->{kind}, 'field', 'kind is field';
    is $sym->{name}, 'name', 'field name is name';
    is $sym->{type}, 'Str', 'field type is Str';
    is $sym->{struct_name}, 'Product', 'struct via chained resolve';
};

# ── Hover on newtype ->base accessor ──────────────

subtest 'hover shows inner type for newtype ->base' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Types.pm" or die;
    print $fh <<'PERL';
package Types;
use v5.40;
use Typist;
newtype UserId => 'Int';
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Types;
sub get_raw :sig((UserId) -> Int) ($uid) {
    $uid->base;
}
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'base' at line 5: "    $uid->base;"
    #                              01234567890123
    my $sym = $doc->symbol_at(5, 11);
    ok $sym, 'found symbol for ->base on newtype';
    is $sym->{name}, 'base', 'name is base';
    is $sym->{type}, 'Int', 'inner type is Int';
    ok $sym->{inferred}, 'marked as inferred';

    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'hover response for ->base';
    like $hover->{contents}{value}, qr/base: Int/, 'shows base: Int';
};

# ── Hover on struct->newtype->base chain ──────────

subtest 'hover shows inner type for struct->newtype->base chain' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Models.pm" or die;
    print $fh <<'PERL';
package Models;
use v5.40;
use Typist;
newtype OrderId => 'Int';
struct Order => (id => OrderId, total => Int);
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Models;
sub get_raw_id :sig((Order) -> Int) ($order) {
    $order->id->base;
}
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'id' at line 5: "    $order->id->base;"
    #                            01234567890123456
    my $sym_id = $doc->symbol_at(5, 12);
    ok $sym_id, 'found symbol for ->id';
    is $sym_id->{kind}, 'field', 'id is field';
    is $sym_id->{name}, 'id', 'field name is id';
    like $sym_id->{type}, qr/OrderId/, 'field type is OrderId';

    # Hover on 'base' at line 5: "    $order->id->base;"
    #                              0         1
    #                              01234567890123456789
    my $sym_base = $doc->symbol_at(5, 16);
    ok $sym_base, 'found symbol for ->id->base chain';
    is $sym_base->{name}, 'base', 'name is base';
    is $sym_base->{type}, 'Int', 'inner type is Int through chain';
};

# ── _format_field unit test ──────────────────────

subtest '_format_field unit test' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind        => 'field',
        name        => 'age',
        type        => 'Int',
        struct_name => 'Person',
        optional    => 0,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'hover response for field';
    like $hover->{contents}{value}, qr/\(Person\) age: Int/, 'required field format';

    my $opt_sym = +{
        kind        => 'field',
        name        => 'email',
        type        => 'Str',
        struct_name => 'User',
        optional    => 1,
    };
    my $opt_hover = Typist::LSP::Hover->hover($opt_sym);
    ok $opt_hover, 'hover response for optional field';
    like $opt_hover->{contents}{value}, qr/\(User\) email\?: Str/, 'optional field format with ?';
};

# ── Hover includes word range ─────────────────────

subtest 'hover response includes range for highlighted word' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
add(1, 2);
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on 'add' definition
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    my $range = $hover->{result}{range};
    ok $range, 'hover result includes range';
    is $range->{start}{line}, 1, 'range start line';
    is $range->{start}{character}, 4, 'range start character (s-u-b-space-a)';
    is $range->{end}{line}, 1, 'range end line';
    is $range->{end}{character}, 7, 'range end character (add = 3 chars)';
};

# ── Hover shows unannotated note ──────────────────

subtest 'hover shows unannotated note on function' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind         => 'function',
        name         => 'helper',
        params_expr  => ['Any'],
        returns_expr => undef,
        eff_expr     => '[*]',
        unannotated  => 1,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover response';
    like $hover->{contents}{value}, qr/\*unannotated\*/, 'shows unannotated note';
};

# ── Hover shows constructor note ───────────────────

subtest 'hover shows constructor note' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind         => 'function',
        name         => 'Circle',
        params_expr  => ['Int'],
        returns_expr => 'Shape',
        constructor  => 1,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover response';
    like $hover->{contents}{value}, qr/\*constructor of `Shape`\*/, 'shows constructor of Shape';
};

# ── Hover shows builtin note ──────────────────────

subtest 'hover shows builtin note' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind         => 'function',
        name         => 'push',
        params_expr  => ['ArrayRef[Any]', '...Any'],
        returns_expr => 'Int',
        builtin      => 1,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover response';
    like $hover->{contents}{value}, qr/\*Perl builtin\*/, 'shows Perl builtin note';
};

# ── Hover shows Typist builtin note ───────────────

subtest 'hover shows Typist builtin note' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind            => 'function',
        name            => 'typedef',
        params_expr     => ['...Any'],
        returns_expr    => 'Void',
        builtin         => 1,
        typist_builtin  => 1,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover response';
    like $hover->{contents}{value}, qr/\*Typist builtin\*/, 'shows Typist builtin note';
    unlike $hover->{contents}{value}, qr/\*Perl builtin\*/, 'does not show Perl builtin';
};

# ── Hover shows unknown type ──────────────────────

subtest 'hover shows unknown note for unresolvable variable' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind     => 'variable',
        name     => '$mystery',
        type     => 'Any',
        inferred => 1,
        unknown  => 1,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover response';
    like $hover->{contents}{value}, qr/\*type unknown\*/, 'shows type unknown note';
    unlike $hover->{contents}{value}, qr/\*inferred\*/, 'does not show inferred when unknown';
};

# ── Hover shows narrowed variable ─────────────────

subtest 'hover shows narrowed note for type-narrowed variable' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind     => 'variable',
        name     => '$x',
        type     => 'Int',
        inferred => 1,
        narrowed => 1,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover response';
    like $hover->{contents}{value}, qr/\*narrowed\*/, 'shows narrowed note';
    unlike $hover->{contents}{value}, qr/\*inferred\*/, 'does not show inferred when narrowed';
};

# ── Hover on function-local unannotated variable accessor ──

subtest 'hover shows field type for local unannotated variable accessor' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Node.pm" or die;
    print $fh <<'PERL';
package Node;
use v5.40;
use Typist;
struct Node => (label => Str, value => Int);
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Node;
sub format_node :sig((Node) -> Str) ($node) {
    my $copy = $node;
    $copy->label;
}
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on 'label' at line 6: "    $copy->label;"
    #                               0123456789012345
    my $sym = $doc->symbol_at(6, 12);
    ok $sym, 'found symbol for local var accessor';
    is $sym->{kind}, 'field', 'kind is field';
    is $sym->{name}, 'label', 'field name is label';
    is $sym->{type}, 'Str', 'field type is Str';
    is $sym->{struct_name}, 'Node', 'struct name is Node';

    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'hover response for local var accessor';
    like $hover->{contents}{value}, qr/\(Node\) label: Str/, 'shows (Node) label: Str';
};

# ── Hover on same-name local var in multiple functions ──

subtest 'hover resolves same-name local var in second function' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Ids.pm" or die;
    print $fh <<'PERL';
package Ids;
use v5.40;
use Typist;
newtype OrderId => 'Int';
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Ids;
sub process :sig((OrderId) -> Str) ($oid) {
    my $key = $oid->base;
    "$key";
}
sub refund :sig((OrderId) -> Str) ($oid) {
    my $key = $oid->base;
    "$key";
}
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Hover on '$key' in refund (line 9): "    my $key = $oid->base;"
    #                                      01234567
    my $sym = $doc->symbol_at(9, 8);
    ok $sym, 'found symbol for $key in second function';
    is $sym->{type}, 'Int', '$key in refund is Int (not Any)';
};

# ── Hover on accessor narrowed by defined() ──────

subtest 'hover narrows optional accessor inside defined() guard' => sub {
    require File::Temp;
    require File::Path;
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;
    require Typist::LSP::Hover;

    my $dir = File::Temp::tempdir(CLEANUP => 1);
    File::Path::make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Customer.pm" or die;
    print $fh <<'PERL';
package Customer;
use v5.40;
use Typist;
struct Customer => (name => Str, phone => optional(Str));
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my $source = <<'PERL';
package App;
use v5.40;
use Typist;
use Customer;
sub greet :sig((Customer) -> Str) ($customer) {
    if (defined($customer->phone)) {
        $customer->phone;
    } else {
        "no phone";
    }
}
PERL

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///app.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Line 6 (0-indexed): "        $customer->phone;"
    #                       0123456789012345678901
    my $sym = $doc->symbol_at(6, 20);
    ok $sym, 'found symbol for narrowed accessor';
    is $sym->{kind}, 'field', 'kind is field';
    is $sym->{name}, 'phone', 'field name is phone';
    is $sym->{type}, 'Str', 'field type is Str';
    is $sym->{optional}, 0, 'optional is 0 (narrowed by defined)';

    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'hover response for narrowed accessor';
    like $hover->{contents}{value}, qr/\(Customer\) phone: Str/, 'shows (Customer) phone: Str (no ?)';
    unlike $hover->{contents}{value}, qr/phone\?/, 'does not show phone? marker';

    # Outside the if-block: line 8 "        \"no phone\";" — no accessor to test,
    # but verify the un-narrowed case by hovering on the same accessor outside guard
    my $source2 = <<'PERL';
package App2;
use v5.40;
use Typist;
use Customer;
sub show :sig((Customer) -> Str) ($customer) {
    $customer->phone;
}
PERL

    my $doc2 = Typist::LSP::Document->new(
        uri     => 'file:///app2.pm',
        content => $source2,
        version => 1,
    );
    $doc2->analyze(workspace_registry => $ws->registry);

    # Line 5 (0-indexed): "    $customer->phone;"
    my $sym2 = $doc2->symbol_at(5, 16);
    ok $sym2, 'found symbol for un-narrowed accessor';
    is $sym2->{optional}, 1, 'optional is 1 (not narrowed)';
};

# ── Hash key should not resolve as builtin ──────

subtest 'hash key "log" does not resolve as Perl builtin' => sub {
    require Typist::LSP::Workspace;
    require Typist::LSP::Document;

    my $source = <<'PERL';
package App;
use v5.40;
handle Logger => +{
    log => sub ($msg) { say $msg },
};
PERL

    my $ws = Typist::LSP::Workspace->new;
    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///test.pm',
        content => $source,
        version => 1,
    );
    $doc->analyze(workspace_registry => $ws->registry);

    # Line 3 (0-indexed): "    log => sub ($msg) { say $msg },"
    # "log" starts at col 4
    my $sym = $doc->symbol_at(3, 5);

    # Should NOT resolve as Perl builtin log (Num) -> Num
    if ($sym) {
        ok !$sym->{builtin}, 'hash key "log" is not a builtin';
    } else {
        pass 'hash key "log" returns no symbol (correct: not a builtin)';
    }
};

# ── Hover displays Array/Hash for sigil variables ──

subtest 'hover shows Array[Int] for @arr variable' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind     => 'variable',
        name     => '@arr',
        type     => 'ArrayRef[Int]',
        inferred => 1,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover';
    like $hover->{contents}{value}, qr/\@arr: Array\[Int\]/, '@arr displays as Array[Int]';
    unlike $hover->{contents}{value}, qr/ArrayRef/, 'ArrayRef replaced for @-sigil';
};

subtest 'hover shows Hash[Str, Int] for %hash variable' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind     => 'variable',
        name     => '%config',
        type     => 'HashRef[Str, Int]',
        inferred => 1,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover';
    like $hover->{contents}{value}, qr/%config: Hash\[Str, Int\]/, '%config displays as Hash[Str, Int]';
    unlike $hover->{contents}{value}, qr/HashRef/, 'HashRef replaced for %-sigil';
};

subtest 'hover keeps ArrayRef for $scalar variable' => sub {
    require Typist::LSP::Hover;

    my $sym = +{
        kind     => 'variable',
        name     => '$ref',
        type     => 'ArrayRef[Int]',
        inferred => 1,
    };
    my $hover = Typist::LSP::Hover->hover($sym);
    ok $hover, 'got hover';
    like $hover->{contents}{value}, qr/\$ref: ArrayRef\[Int\]/, '$ref keeps ArrayRef[Int]';
};

done_testing;
