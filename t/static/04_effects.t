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

sub greet :Type((Str) -> Str !Eff(Console)) ($name) {
    return "Hello, $name!";
}

sub main :Type(() -> Void !Eff(Console | State)) () {
    greet("world");
}
PERL

    ok exists $result->{functions}{greet}, 'greet extracted';
    is $result->{functions}{greet}{eff_expr}, 'Console', 'eff_expr for greet';

    ok exists $result->{functions}{main}, 'main extracted';
    is $result->{functions}{main}{eff_expr}, 'Console | State', 'eff_expr for main';
};

subtest 'Extractor: function with effect only' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package EffOnly;
use v5.40;

sub doIO :Type(() -> Any !Eff(IO)) () {
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

sub greet :Type((Str) -> Str !Eff(Console)) ($name) {
    return "Hello, $name!";
}

sub main :Type(() -> Void !Eff(Console)) () {
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

sub effectful :Type((Str) -> Str !Eff(Console | State)) ($x) {
    return $x;
}

sub caller_fn :Type(() -> Str !Eff(Console)) () {
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

sub io_fn :Type((Str) -> Str !Eff(IO)) ($x) {
    return $x;
}

sub pure_fn :Type((Str) -> Str) ($x) {
    io_fn($x);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff_diags > 0, 'mismatch detected: pure calls effectful';
    like $eff_diags[0]{message}, qr/no :Eff/, 'reports missing :Eff annotation';
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

sub needs_a :Type(() -> Void !Eff(A)) () { }

sub has_abc :Type(() -> Void !Eff(A | B | C)) () {
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

sub bad :Type(() -> Void !Eff(Nonexistent)) () { }
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

sub logged :Type(() -> Void !Eff(Log | r)) () { }
PERL

    my @undecl = grep { $_->{kind} eq 'UndeclaredRowVar' } @{$result->{diagnostics}};
    ok @undecl > 0, 'undeclared row var detected';
    like $undecl[0]{message}, qr/\br\b/, 'reports the undeclared row variable';
};

# ── Unannotated function → any effect ───────────

subtest 'Analyzer: annotated caller calls unannotated local function' => sub {
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

sub main_fn :Type((Str) -> Str !Eff(Console)) ($s) {
    helper($s);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff_diags > 0, 'calling unannotated function flagged';
    like $eff_diags[0]{message}, qr/unannotated.*helper/, 'reports unannotated callee';
};

subtest 'Analyzer: pure caller calls unannotated local function' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package PureCallsUnannotated;
use v5.40;

sub helper ($x) {
    return $x;
}

sub pure_fn :Type((Str) -> Str) ($s) {
    helper($s);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff_diags > 0, 'pure fn calling unannotated function flagged';
    like $eff_diags[0]{message}, qr/unannotated.*helper/, 'reports unannotated callee';
};

subtest 'Analyzer: annotated callee without effect is pure' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package PartiallyAnnotated;
use v5.40;

sub helper :Type((Str) -> Str) ($x) {
    return $x;
}

sub caller_fn :Type((Str) -> Str) ($s) {
    helper($s);
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff_diags, 0, 'annotated function without effect is pure — no error';
};

# ── Builtin functions are Eff(*) ─────────────────

subtest 'Analyzer: builtin say in Eff(Console) function is flagged' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package BuiltinInEffect;
use v5.40;

sub greet :Type((Str) -> Void !Eff(Console)) ($name) {
    say "Hello, $name";
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff_diags > 0, 'calling builtin say inside Eff(Console) is flagged';
    like $eff_diags[0]{message}, qr/unannotated.*say/, 'reports unannotated builtin say';
};

subtest 'Analyzer: builtin in pure function is flagged' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package BuiltinInPure;
use v5.40;

sub compute :Type((Int) -> Int) ($n) {
    print "debug";
    $n * 2;
}
PERL

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff_diags > 0, 'calling builtin print inside pure function is flagged';
    like $eff_diags[0]{message}, qr/unannotated.*print/, 'reports unannotated builtin print';
};

# ── Declared builtins override Eff(*) ────────────

subtest 'Analyzer: declared say with Console — no error in Eff(Console)' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package DeclaredBuiltin;
use v5.40;

declare say => '(Str) -> Void !Eff(Console)';

sub greet :Type((Str) -> Void !Eff(Console)) ($name) {
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

declare die => '(Any) -> Never !Eff(Abort)';

sub handler :Type((Str) -> Void !Eff(Console)) ($msg) {
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

sub count :Type((Str) -> Int) ($s) {
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
sub helper ($x) { $x }
sub main_fn :Type((Str) -> Str !Eff(Console)) ($s) {
    # @typist-ignore
    helper($s);
}
PERL
    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    is scalar @eff, 0, '@typist-ignore suppresses EffectMismatch';
};

done_testing;
