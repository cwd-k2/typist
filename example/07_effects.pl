#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  07 — Algebraic Effects
#
#  Effect system for tracking and handling side effects:
#
#    effect Console => +{ writeLine => '(Str) -> Void' };
#    Console::writeLine("hello");
#    handle { ... } Console => +{ writeLine => sub ($msg) { ... } };
#
#  Effects are phantom in the type annotations — they track
#  what a function MAY do, without runtime overhead in the
#  annotation itself.  Runtime execution uses Effect::op/handle.
# ═══════════════════════════════════════════════════════════

# ── Effect Definitions ────────────────────────────────────
#
# effect Name => +{ op => '(Params) -> ReturnType' }
# Defines an effect with named operations and their signatures.
# Operations are auto-installed as qualified subs (e.g., Console::writeLine).

BEGIN {
    effect Console => +{
        readLine  => '() -> Str',
        writeLine => '(Str) -> Void',
    };

    effect Logger => +{
        log => '(Str) -> Void',
    };

    effect State => +{
        get => '() -> Int',
        put => '(Int) -> Void',
    };
}

# ── Effect Annotations ────────────────────────────────────
#
# !Eff(Name) declares that a function may perform an effect.

sub greet :Type((Str) -> Str !Eff(Console)) ($name) {
    Console::writeLine("Hello, $name!");
    "greeted $name";
}

sub log_msg :Type((Str) -> Str !Eff(Logger)) ($msg) {
    Logger::log("[LOG] $msg");
    $msg;
}

# ── Handling Effects ──────────────────────────────────────
#
# handle { BODY } Effect => +{ op => sub { ... } }
#
# Installs scoped handlers, executes BODY, auto-cleans up.
# The handler receives the arguments from the effect call and
# provides the implementation.

say "── Console handler ────────────────────────────";

my $result = handle {
    greet("Alice");
} Console => +{
    writeLine => sub ($msg) { say "  [stdout] $msg" },
    readLine  => sub        { "mock input" },
};

say "  result: $result";

# ── Swappable Implementations ────────────────────────────
#
# The same effectful code can run under different handlers.
# This is the core value of algebraic effects: separating
# WHAT to do from HOW to do it.

say "";
say "── Logger handler (stderr) ────────────────────";

handle {
    log_msg("starting process");
    log_msg("process complete");
} Logger => +{
    log => sub ($msg) { say "  [stderr] $msg" },
};

say "";
say "── Logger handler (collect) ───────────────────";

my @logs;
handle {
    log_msg("event A");
    log_msg("event B");
} Logger => +{
    log => sub ($msg) { push @logs, $msg },
};

say "  collected: ", join(", ", @logs);

# ── Multiple Effects ──────────────────────────────────────
#
# !Eff(A | B) declares a function using multiple effects.
# handle blocks can compose.

sub greet_logged :Type((Str) -> Str !Eff(Console | Logger)) ($name) {
    Logger::log("greeting $name");
    Console::writeLine("Hello, $name!");
    "greeted $name";
}

say "";
say "── Multiple effects ───────────────────────────";

handle {
    handle {
        greet_logged("Bob");
    } Console => +{
        writeLine => sub ($msg) { say "  [out] $msg" },
        readLine  => sub        { "" },
    };
} Logger => +{
    log => sub ($msg) { say "  [log] $msg" },
};

# ── Stateful Effect Handler ───────────────────────────────
#
# Effects can model mutable state with get/put.

sub counter :Type(() -> Int !Eff(State)) () {
    my $n = State::get();
    State::put($n + 1);
    State::put(State::get() + 1);
    State::get();
}

say "";
say "── State effect ───────────────────────────────";

my $state = 0;
my $final = handle {
    counter();
} State => +{
    get => sub        { $state },
    put => sub ($val) { $state = $val },
};

say "  final state: $final";

# ── Row Polymorphism ──────────────────────────────────────
#
# <r: Row> declares a row variable — an open-ended set of
# effects.  !Eff(Logger | r) means "at least Logger, plus
# whatever r adds."  Callers can instantiate r with
# additional effects.

sub with_log :Type(<r: Row>(Str) -> Str !Eff(Logger | r)) ($msg) {
    Logger::log($msg);
    $msg;
}

say "";
say "── Row polymorphism ───────────────────────────";

# Caller with Logger + Console can call with_log (r = Console)
handle {
    handle {
        my $x = with_log("hello from row-poly");
        Console::writeLine("result: $x");
    } Console => +{
        writeLine => sub ($msg) { say "  [out] $msg" },
        readLine  => sub        { "" },
    };
} Logger => +{
    log => sub ($msg) { say "  [log] $msg" },
};

# ── Effect Inclusion (Static Checking) ────────────────────
#
# The static analyzer (CHECK phase and LSP) enforces:
#
#   caller !Eff(A)     calling callee !Eff(A)         → OK
#   caller !Eff(A|B)   calling callee !Eff(A)         → OK (superset)
#   caller !Eff(A)     calling callee !Eff(A|B)       → NG (missing B)
#   caller (pure)      calling callee !Eff(A)         → NG
#   caller (annotated) calling unannotated             → NG (Eff(*))
#
# See lsp/effects.pm for an LSP diagnostic showcase.

say "";
say "── Pure function (no effects) ─────────────────";

sub pure_add :Type((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

say "  pure_add(2, 3) = ", pure_add(2, 3);
