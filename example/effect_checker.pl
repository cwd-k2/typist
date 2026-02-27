#!/usr/bin/env perl
use v5.40;
use lib 'lib';

use Typist::Static::Analyzer;
use Typist::Registry;
use Typist::Effect;

# ── Effect Inclusion: Static Analysis Demo ─────
#
# The static analyzer enforces that a function can only call
# functions whose effects are a subset of its own declared effects.
#
#   caller :Eff(A)       can call   callee :Eff(A)       ✓
#   caller :Eff(A | B)   can call   callee :Eff(A)       ✓  (superset)
#   caller :Eff(A)       cannot call callee :Eff(A | B)  ✗  (missing B)
#   caller (pure)        cannot call callee :Eff(A)       ✗  (no effects)
#   caller (annotated)   cannot call unannotated callee   ✗  (Eff(*))

my $sep = '─' x 60;

# Shared workspace registry with effect definitions
sub make_registry {
    my $reg = Typist::Registry->new;
    $reg->register_effect('Console', Typist::Effect->new(name => 'Console', operations => +{}));
    $reg->register_effect('State',   Typist::Effect->new(name => 'State',   operations => +{}));
    $reg->register_effect('Log',     Typist::Effect->new(name => 'Log',     operations => +{}));
    $reg;
}

sub analyze_and_show ($label, $source) {
    say "\n$sep";
    say "  $label";
    say $sep;

    # Show the source (indented)
    for my $line (split /\n/, $source) {
        say "  │ $line";
    }
    say "  │";

    my $result = Typist::Static::Analyzer->analyze(
        $source,
        workspace_registry => make_registry(),
    );

    my @eff_diags = grep { $_->{kind} eq 'EffectMismatch' } $result->{diagnostics}->@*;

    if (@eff_diags) {
        say "  ⚠ Diagnostics:";
        for my $d (@eff_diags) {
            say "    line $d->{line}: $d->{message}";
        }
    }
    else {
        say "  ✓ No effect errors.";
    }
}

say "Effect Inclusion Checker — Static Analysis Demo";

# ── 1. OK: caller's effects include callee's ───

analyze_and_show('1. Caller has Console, calls Console callee → OK', <<'PERL');
package Case1;
use v5.40;

sub write_msg :Params(Str) :Returns(Str) :Eff(Console) ($s) {
    return $s;
}

sub main :Returns(Void) :Eff(Console) () {
    write_msg("hello");
}
PERL

# ── 2. OK: caller's effects are superset ────────

analyze_and_show('2. Caller has Console|State|Log, calls Console callee → OK (superset)', <<'PERL');
package Case2;
use v5.40;

sub write_msg :Params(Str) :Returns(Str) :Eff(Console) ($s) {
    return $s;
}

sub main :Returns(Void) :Eff(Console | State | Log) () {
    write_msg("hello");
}
PERL

# ── 3. NG: caller missing callee's effect ───────

analyze_and_show('3. Caller has Console, calls Console|State callee → NG (missing State)', <<'PERL');
package Case3;
use v5.40;

sub stateful :Params(Str) :Returns(Str) :Eff(Console | State) ($x) {
    return $x;
}

sub caller_fn :Returns(Str) :Eff(Console) () {
    stateful("hello");
}
PERL

# ── 4. NG: pure caller calls effectful callee ───

analyze_and_show('4. Pure caller (no :Eff) calls Console callee → NG', <<'PERL');
package Case4;
use v5.40;

sub io_fn :Params(Str) :Returns(Str) :Eff(Console) ($x) {
    return $x;
}

sub pure_fn :Params(Str) :Returns(Str) ($x) {
    io_fn($x);
}
PERL

# ── 5. NG: annotated caller calls unannotated ───

analyze_and_show('5. Annotated caller calls unannotated callee → NG (Eff(*))', <<'PERL');
package Case5;
use v5.40;

sub helper ($x) {
    return $x;
}

sub safe_fn :Params(Str) :Returns(Str) :Eff(Console) ($s) {
    helper($s);
}
PERL

# ── 6. OK: unannotated calls anything (no check) ─

analyze_and_show('6. Unannotated caller calls anything → no check (gradual)', <<'PERL');
package Case6;
use v5.40;

sub io_fn :Params(Str) :Returns(Str) :Eff(Console) ($x) {
    return $x;
}

sub untyped ($x) {
    io_fn($x);
}
PERL

say "\n$sep";
say "  Done.";
say $sep;
