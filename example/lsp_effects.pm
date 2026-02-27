package LSP::Effects;
use v5.40;
use lib 'lib';
use Typist;

# This file demonstrates effect checking visible via the Typist LSP server.
# Open this file in an editor with the Typist LSP to see diagnostics.
#
# Expected diagnostics (marked with ✗):
#   - line 38: caller_fn() missing 'State' effect
#   - line 47: pure_fn() calls effectful io_fn() without :Eff
#   - line 56: safe_fn() calls unannotated helper() which may perform any effect

# ── Effect Declarations ──────────────────────────

effect Console => +{};
effect State   => +{};

# ── ✓ OK: caller's effects include callee's ────

sub write_msg :Params(Str) :Returns(Str) :Eff(Console) ($s) {
    $s;
}

sub main_ok :Returns(Str) :Eff(Console | State) () {
    write_msg("hello");     # ✓ Console ⊆ {Console, State}
}

# ── ✗ NG: caller missing callee's effect ────────

sub stateful :Params(Str) :Returns(Str) :Eff(Console | State) ($x) {
    $x;
}

sub caller_fn :Returns(Str) :Eff(Console) () {
    stateful("hello");      # ✗ State not in {Console}
}

# ── ✗ NG: pure caller calls effectful callee ────

sub io_fn :Params(Str) :Returns(Str) :Eff(Console) ($x) {
    $x;
}

sub pure_fn :Params(Str) :Returns(Str) ($x) {
    io_fn($x);              # ✗ pure has no :Eff, but io_fn requires Console
}

# ── ✗ NG: annotated caller calls unannotated ────

sub helper ($x) {
    $x;
}

sub safe_fn :Params(Str) :Returns(Str) :Eff(Console) ($s) {
    helper($s);             # ✗ helper is unannotated → Eff(*), any effect
}

# ── ✓ OK: unannotated caller — no check ─────────

sub untyped ($x) {
    io_fn($x);              # ✓ gradual: unannotated caller is not checked
}

1;
