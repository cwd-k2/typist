use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;
use Typist::Static::Extractor;
use Typist::Registry;

# ── Extractor captures :Type with effects ────────

subtest 'Extractor captures eff_expr' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package EffTest;
use v5.40;

sub greet :sig((Str) -> Str ![Console]) ($name) {
    return "Hello, $name!";
}

sub main :sig(() -> Void ![Console, State]) () {
    greet("world");
}
PERL

    ok exists $result->{functions}{greet}, 'greet extracted';
    is $result->{functions}{greet}{eff_expr}, 'Console', 'eff_expr for greet';

    ok exists $result->{functions}{main}, 'main extracted';
    is $result->{functions}{main}{eff_expr}, 'Console, State', 'eff_expr for main';
};

subtest 'Extractor: function with effect only' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package EffOnly;
use v5.40;

sub doIO :sig(() -> Any ![IO]) () {
    42;
}
PERL

    ok exists $result->{functions}{doIO}, 'eff-only function extracted';
    is $result->{functions}{doIO}{eff_expr}, 'IO', 'eff_expr captured';
};

# ── Analyzer: effect mismatch detection ─────────

subtest 'Analyzer: clean code with effects — no diagnostics' => sub {
    # Set up effects in a workspace registry
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{ writeLine => 'CodeRef[Str -> Void]' },
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package Clean;
use v5.40;

sub greet :sig((Str) -> Str ![Console]) ($name) {
    return "Hello, $name!";
}

sub main :sig(() -> Void ![Console]) () {
    greet("world");
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'no effect mismatch';
};

subtest 'Analyzer: caller missing callee effect' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));
    $ws_reg->register_effect('State', Typist::Effect->new(
        name => 'State', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package Missing;
use v5.40;

sub effectful :sig((Str) -> Str ![Console, State]) ($x) {
    return $x;
}

sub caller_fn :sig(() -> Str ![Console]) () {
    effectful("hello");
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff_diags > 0, 'effect mismatch detected';
    like $eff_diags[0]{message}, qr/State/, 'missing State effect reported';
};

subtest 'Analyzer: caller has no effect but callee does' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('IO', Typist::Effect->new(
        name => 'IO', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package NoEff;
use v5.40;

sub io_fn :sig((Str) -> Str ![IO]) ($x) {
    return $x;
}

sub pure_fn :sig((Str) -> Str) ($x) {
    io_fn($x);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff_diags > 0, 'mismatch detected: pure calls effectful';
    like $eff_diags[0]{message}, qr/no effect annotation/, 'reports missing effect annotation';
};

subtest 'Analyzer: effect superset is OK' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('A', Typist::Effect->new(name => 'A', operations => +{}));
    $ws_reg->register_effect('B', Typist::Effect->new(name => 'B', operations => +{}));
    $ws_reg->register_effect('C', Typist::Effect->new(name => 'C', operations => +{}));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package Superset;
use v5.40;

sub needs_a :sig(() -> Void ![A]) () { }

sub has_abc :sig(() -> Void ![A, B, C]) () {
    needs_a();
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'superset of effects is fine';
};

# ── Analyzer: unknown effect labels ─────────────

subtest 'Analyzer: unknown effect label' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package Unknown;
use v5.40;

sub bad :sig(() -> Void ![Nonexistent]) () { }
PERL

    my @unknown = grep { $_->{kind} eq 'UnknownEffect' } @{$result->{diagnostics}};
    ok @unknown > 0, 'unknown effect detected';
    like $unknown[0]{message}, qr/Nonexistent/, 'reports the unknown effect name';
};

# ── Analyzer: undeclared row variable ────────────

subtest 'Analyzer: undeclared row variable' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Log', Typist::Effect->new(name => 'Log', operations => +{}));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package BadRow;
use v5.40;

sub logged :sig(() -> Void ![Log, r]) () { }
PERL

    my @undecl = grep { $_->{kind} eq 'UndeclaredRowVar' } @{$result->{diagnostics}};
    ok @undecl > 0, 'undeclared row var detected';
    like $undecl[0]{message}, qr/\br\b/, 'reports the undeclared row variable';
};

# ── Unannotated function → pure (no effect) ─────

subtest 'Analyzer: annotated caller calls unannotated local function — no error' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package UnannotatedCallee;
use v5.40;

sub helper ($x) {
    return $x;
}

sub main_fn :sig((Str) -> Str ![Console]) ($s) {
    helper($s);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'unannotated callee is pure — no EffectMismatch';
};

subtest 'Analyzer: pure caller calls unannotated local function — no error' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package PureCallsUnannotated;
use v5.40;

sub helper ($x) {
    return $x;
}

sub pure_fn :sig((Str) -> Str) ($s) {
    helper($s);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'unannotated callee is pure — no EffectMismatch';
};

subtest 'Analyzer: annotated callee without effect is pure' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package PartiallyAnnotated;
use v5.40;

sub helper :sig((Str) -> Str) ($x) {
    return $x;
}

sub caller_fn :sig((Str) -> Str) ($s) {
    helper($s);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'annotated function without effect is pure — no error';
};

# ── Builtin functions are [*] ─────────────────────

subtest 'Analyzer: builtin say in ![Console] function — IO is ambient' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package BuiltinInEffect;
use v5.40;

sub greet :sig((Str) -> Void ![Console]) ($name) {
    say "Hello, $name";
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'IO is ambient — no EffectMismatch for builtin say';
};

subtest 'Analyzer: builtin in pure function — IO is ambient' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package BuiltinInPure;
use v5.40;

sub compute :sig((Int) -> Int) ($n) {
    print "debug";
    $n * 2;
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'IO is ambient — no EffectMismatch for builtin print';
};

# ── Declared builtins override [*] ────────────────

subtest 'Analyzer: declared say with Console — no error in ![Console]' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package DeclaredBuiltin;
use v5.40;

declare say => '(Str) -> Void ![Console]';

sub greet :sig((Str) -> Void ![Console]) ($name) {
    say "Hello, $name";
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'no effect mismatch when say is declared with Console';
};

subtest 'Analyzer: declared die with Abort — error when caller only has Console' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));
    $ws_reg->register_effect('Abort', Typist::Effect->new(
        name => 'Abort', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package DeclaredDie;
use v5.40;

declare die => '(Any) -> Never ![Abort]';

sub handler :sig((Str) -> Void ![Console]) ($msg) {
    die("fatal: $msg");
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff_diags > 0, 'effect mismatch detected for declared die';
    like $eff_diags[0]{message}, qr/Abort/, 'reports missing Abort effect';
};

subtest 'Analyzer: declared pure builtin — no effect error' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package DeclaredPure;
use v5.40;

declare length => '(Str) -> Int';

sub count :sig((Str) -> Int) ($s) {
    length($s);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'declared pure builtin causes no effect error';
};

# ── @typist-ignore ────────────────────────────────

subtest '@typist-ignore suppresses EffectMismatch' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package Ignore;
use v5.40;
sub pure_fn :sig((Str) -> Str) ($s) {
    # @typist-ignore
    print "debug";
    $s;
}
PERL
    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff, 0, '@typist-ignore suppresses EffectMismatch for builtin print';
};

# ── Column Precision ────────────────────────────

subtest 'diagnostic: col on EffectMismatch' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));
    $ws_reg->register_effect('State', Typist::Effect->new(
        name => 'State', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package ColTest;
use v5.40;

sub effectful :sig((Str) -> Str ![Console, State]) ($x) {
    return $x;
}

sub caller_fn :sig(() -> Str ![Console]) () {
    effectful("hello");
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff_diags > 0, 'effect mismatch detected';
    ok $eff_diags[0]{col} > 0, 'col is set on EffectMismatch';
};

subtest 'diagnostic: no col on unannotated callee (pure)' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ColUnannotated;
use v5.40;

sub helper ($x) { $x }

sub main_fn :sig((Str) -> Str) ($s) {
    helper($s);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'unannotated callee is pure — no EffectMismatch';
};

# ── Decl effect: declaration builtins ─────────

subtest 'Analyzer: enum in ![Decl] function → no error' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package EnumDecl;
use v5.40;

sub setup :sig(() -> Void ![Decl]) () {
    enum Color => qw(Red Green Blue);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'enum in ![Decl] function — no effect error';
};

subtest 'Analyzer: eval in ![Exn] function → no error' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package EvalExn;
use v5.40;

sub safe_eval :sig((Any) -> Any ![Exn]) ($code) {
    eval($code);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'eval in ![Exn] function — no effect error';
};

subtest 'Analyzer: eval in pure function — Exn is ambient' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package EvalPure;
use v5.40;

sub try_parse :sig((Str) -> Any) ($s) {
    eval($s);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'Exn is ambient — no EffectMismatch for eval';
};

# ── Effect Inference ──────────────────────────

subtest 'infer_effects: unannotated function calling say() → IO' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package EffInfer1;
use v5.40;

sub hello() {
    say "hello";
}
PERL

    my $ie = $result->{inferred_effects} // [];
    my ($hello) = grep { $_->{name} eq 'hello' } @$ie;
    ok $hello, 'hello appears in inferred_effects';
    ok grep({ $_ eq 'IO' } $hello->{labels}->@*), 'IO label inferred';
    ok !$hello->{unknown}, 'no unknown flag';
};

subtest 'infer_effects: annotated function not included' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package EffInfer2;
use v5.40;

sub greet :sig((Str) -> Void ![IO]) ($name) {
    say "Hello, $name";
}
PERL

    my $ie = $result->{inferred_effects} // [];
    my ($greet) = grep { $_->{name} eq 'greet' } @$ie;
    ok !$greet, 'annotated function not in inferred_effects';
};

subtest 'infer_effects: unannotated calling unannotated → pure, no entry' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package EffInfer3;
use v5.40;

sub helper() {
    say "side-effect";
}

sub caller_fn() {
    helper();
}
PERL

    my $ie = $result->{inferred_effects} // [];
    my ($caller) = grep { $_->{name} eq 'caller_fn' } @$ie;
    # helper() is unannotated → pure → skipped. No effects collected for caller_fn.
    ok !$caller, 'caller_fn has no inferred effects (unannotated callee is pure)';
};

subtest 'infer_effects: pure unannotated function → no entry' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package EffInfer4;
use v5.40;

sub add($a, $b) {
    return $a + $b;
}
PERL

    my $ie = $result->{inferred_effects} // [];
    my ($add) = grep { $_->{name} eq 'add' } @$ie;
    ok !$add, 'pure unannotated function has no inferred_effects entry';
};

# ══════════════════════════════════════════════════════
# Effect Discharge: handle-aware EffectChecker
# ══════════════════════════════════════════════════════

subtest 'handle discharges single effect — no mismatch' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{ log => '(Str) -> Void' },
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package HandleDischarge;
use v5.40;

sub log_fn :sig((Str) -> Void ![Console]) ($msg) {
    return;
}

sub pure_handler :sig(() -> Void) () {
    handle {
        log_fn("hello");
    } Console => +{
        log => sub ($msg) { },
    };
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff, 0, 'handle discharges Console — no EffectMismatch';
};

subtest 'handle partial discharge — remaining effect checked' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));
    $ws_reg->register_effect('DB', Typist::Effect->new(
        name => 'DB', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package PartialDischarge;
use v5.40;

sub db_and_log :sig(() -> Void ![Console, DB]) () {
    return;
}

sub handler :sig(() -> Void ![Console]) () {
    handle {
        db_and_log();
    } DB => +{ query => sub { } };
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff, 0, 'DB discharged by handle, Console declared on caller — clean';
};

subtest 'handle partial discharge — missing remaining effect reported' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));
    $ws_reg->register_effect('DB', Typist::Effect->new(
        name => 'DB', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package PartialMissing;
use v5.40;

sub db_and_log :sig(() -> Void ![Console, DB]) () {
    return;
}

sub handler :sig(() -> Void) () {
    handle {
        db_and_log();
    } DB => +{ query => sub { } };
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff > 0, 'Console not discharged and not declared — EffectMismatch';
    like $eff[0]{message}, qr/Console/, 'reports missing Console';
};

subtest 'handle for wrong effect — no discharge' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));
    $ws_reg->register_effect('DB', Typist::Effect->new(
        name => 'DB', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package WrongHandle;
use v5.40;

sub db_fn :sig(() -> Void ![DB]) () {
    return;
}

sub handler :sig(() -> Void) () {
    handle {
        db_fn();
    } Console => +{ log => sub { } };
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff > 0, 'handle for Console does not discharge DB';
    like $eff[0]{message}, qr/DB/, 'reports missing DB';
};

subtest 'nested handle — inner discharge scoped correctly' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{ log => '(Str) -> Void' },
    ));
    $ws_reg->register_effect('DB', Typist::Effect->new(
        name => 'DB', operations => +{ query => '(Str) -> Str' },
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package NestedHandle;
use v5.40;

sub log_fn :sig((Str) -> Void ![Console]) ($msg) { return }
sub db_fn  :sig((Str) -> Str ![DB]) ($q) { return $q }

sub outer :sig(() -> Void ![Console]) () {
    handle {
        db_fn("SELECT 1");
        log_fn("done");
    } DB => +{ query => sub ($q) { $q } };
    log_fn("after handle");
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff, 0, 'DB discharged inside handle, Console declared — clean';
};

subtest 'call outside handle — not discharged' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('DB', Typist::Effect->new(
        name => 'DB', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package OutsideHandle;
use v5.40;

sub db_fn :sig(() -> Void ![DB]) () { return }

sub caller_fn :sig(() -> Void) () {
    handle {
        1;
    } DB => +{ query => sub { } };
    db_fn();
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff > 0, 'call outside handle block is not discharged';
};

subtest 'infer_effects: handle discharge excluded from inference' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{ log => '(Str) -> Void' },
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package InferDischarge;
use v5.40;

sub log_fn :sig((Str) -> Void ![Console]) ($msg) { return }

sub handler () {
    handle {
        log_fn("hello");
    } Console => +{ log => sub ($msg) { } };
}
PERL

    my $ie = $result->{inferred_effects} // [];
    my ($handler) = grep { $_->{name} eq 'handler' } @$ie;
    ok !$handler, 'handler has no inferred effects — Console discharged by handle';
};

done_testing;
