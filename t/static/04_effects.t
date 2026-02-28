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

sub greet :Type((Str) -> Str ! Console) ($name) {
    return "Hello, $name!";
}

sub main :Type(() -> Void ! Console | State) () {
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

sub doIO :Type(() -> Any ! IO) () {
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

sub greet :Type((Str) -> Str ! Console) ($name) {
    return "Hello, $name!";
}

sub main :Type(() -> Void ! Console) () {
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

sub effectful :Type((Str) -> Str ! Console | State) ($x) {
    return $x;
}

sub caller_fn :Type(() -> Str ! Console) () {
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

sub io_fn :Type((Str) -> Str ! IO) ($x) {
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

sub needs_a :Type(() -> Void ! A) () { }

sub has_abc :Type(() -> Void ! A | B | C) () {
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

sub bad :Type(() -> Void ! Nonexistent) () { }
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

sub logged :Type(() -> Void ! Log | r) () { }
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

sub main_fn :Type((Str) -> Str ! Console) ($s) {
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

done_testing;
