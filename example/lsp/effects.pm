package LSP::Effects;
use v5.40;
use lib 'lib';
use Typist;

# ═══════════════════════════════════════════════════════════
#  LSP Effects Demo — Effect Checking Diagnostics
#
#  Open this file in an editor with the Typist LSP server.
#  Expected diagnostics are marked with # ← DIAGNOSTIC.
#
#  Rules:
#    caller ![A]     calling callee ![A]     → OK
#    caller ![A, B]  calling callee ![A]     → OK (superset)
#    caller ![A]     calling callee ![A, B]  → NG (missing B)
#    caller (pure)   calling callee ![A]     → NG
#    caller (annotated) calling unannotated   → NG ([*])
# ═══════════════════════════════════════════════════════════

# ── Effect Declarations ───────────────────────────────────

effect Console => +{};
effect State   => +{};

# ── OK: caller's effects include callee's ─────────────────

sub write_msg :Type((Str) -> Str ![Console]) ($s) {
    $s;
}

sub main_ok :Type(() -> Str ![Console, State]) () {
    write_msg("hello");     # Console ⊆ {Console, State} → OK
}

# ── NG: caller missing callee's effect ────────────────────

sub stateful :Type((Str) -> Str ![Console, State]) ($x) {
    $x;
}

sub caller_fn :Type(() -> Str ![Console]) () {
    stateful("hello");      # ← DIAGNOSTIC: State not in {Console}
}

# ── NG: pure caller calls effectful callee ────────────────

sub io_fn :Type((Str) -> Str ![Console]) ($x) {
    $x;
}

sub pure_fn :Type((Str) -> Str) ($x) {
    io_fn($x);              # ← DIAGNOSTIC: pure → no effects allowed
}

# ── NG: annotated caller calls unannotated ────────────────

sub unknown_helper ($x) {
    $x;
}

sub safe_fn :Type((Str) -> Str ![Console]) ($s) {
    unknown_helper($s);     # ← DIAGNOSTIC: unannotated → [*]
}

# ── OK: unannotated caller — no check ────────────────────

sub untyped ($x) {
    io_fn($x);              # gradual: unannotated caller is not checked
}

1;
