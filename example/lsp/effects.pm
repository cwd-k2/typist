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
#    caller (any)      calling unannotated    → OK (pure)
# ═══════════════════════════════════════════════════════════

# ── Effect Declarations ───────────────────────────────────

effect Console => +{};
effect State   => +{};

# ── OK: caller's effects include callee's ─────────────────

sub write_msg :sig((Str) -> Str ![Console]) ($s) {
    $s;
}

sub main_ok :sig(() -> Str ![Console, State]) () {
    write_msg("hello");     # Console ⊆ {Console, State} → OK
}

# ── NG: caller missing callee's effect ────────────────────

sub stateful :sig((Str) -> Str ![Console, State]) ($x) {
    $x;
}

sub caller_fn :sig(() -> Str ![Console]) () {
    stateful("hello");      # ← DIAGNOSTIC: State not in {Console}
}

# ── NG: pure caller calls effectful callee ────────────────

sub io_fn :sig((Str) -> Str ![Console]) ($x) {
    $x;
}

sub pure_fn :sig((Str) -> Str) ($x) {
    io_fn($x);              # ← DIAGNOSTIC: pure → no effects allowed
}

# ── OK: annotated caller calls unannotated (pure) ───────

sub unknown_helper ($x) {
    $x;
}

sub safe_fn :sig((Str) -> Str ![Console]) ($s) {
    unknown_helper($s);     # OK: unannotated → pure (no effect)
}

# ── OK: unannotated caller — no check ────────────────────

sub untyped ($x) {
    io_fn($x);              # gradual: unannotated caller is not checked
}

1;
