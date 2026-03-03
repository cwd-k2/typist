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
# ![Name] declares that a function may perform an effect.

sub greet :sig((Str) -> Str ![Console]) ($name) {
    Console::writeLine("Hello, $name!");
    "greeted $name";
}

sub log_msg :sig((Str) -> Str ![Logger]) ($msg) {
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
# ![A, B] declares a function using multiple effects.
# handle blocks can compose.

sub greet_logged :sig((Str) -> Str ![Console, Logger]) ($name) {
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

sub counter :sig(() -> Int ![State]) () {
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
# effects.  ![Logger, r] means "at least Logger, plus
# whatever r adds."  Callers can instantiate r with
# additional effects.

sub with_log :sig(<r: Row>(Str) -> Str ![Logger, r]) ($msg) {
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

# ── Effect Protocols (Stateful Effects) ──────────────────
#
# Protocols add state machines to effects, enforcing operation
# ordering at the type level.  Each operation carries an inline
# protocol('From -> To') transition marker.
#
#   effect DB, [qw(None Connected Authed)] => +{
#       connect => ['sig', protocol('None -> Connected')],
#       ...
#   };
#
# Annotations declare start/end states:
#   ![DB<None -> Authed>]   — transition from None to Authed
#   ![DB<Authed>]           — invariant: stay in Authed

say "";
say "── Effect protocol (database) ─────────────────";

BEGIN {
    effect 'Database', [qw(Disconnected Connected Authenticated)] => +{
        connect    => ['(Str) -> Void',      protocol('Disconnected -> Connected')],
        auth       => ['(Str, Str) -> Void', protocol('Connected -> Authenticated')],
        query      => ['(Str) -> Str',       protocol('Authenticated -> Authenticated')],
        disconnect => ['() -> Void',         protocol('Authenticated -> Disconnected')],
    };
}

# setup transitions: Disconnected → Connected → Authenticated
sub db_setup :sig(() -> Void ![Database<Disconnected -> Authenticated>]) () {
    Database::connect("localhost");
    Database::auth("admin", "secret");
}

# query is invariant: Authenticated → Authenticated
sub db_query :sig((Str) -> Str ![Database<Authenticated>]) ($sql) {
    Database::query($sql);
}

# Full session: Disconnected → Authenticated → Disconnected
sub db_session :sig(() -> Str ![Database<Disconnected -> Disconnected>]) () {
    db_setup();
    my $result = db_query("SELECT 1");
    Database::disconnect();
    $result;
}

my $db_result = handle {
    db_session();
} Database => +{
    connect    => sub ($host) { say "  [db] connecting to $host" },
    auth       => sub ($u, $p) { say "  [db] authenticating $u" },
    query      => sub ($sql) { say "  [db] query: $sql"; "row_data" },
    disconnect => sub { say "  [db] disconnected" },
};

say "  result: $db_result";

# ── Effect Inclusion (Static Checking) ────────────────────
#
# The static analyzer (CHECK phase and LSP) enforces:
#
#   caller ![A]     calling callee ![A]         → OK
#   caller ![A, B]  calling callee ![A]         → OK (superset)
#   caller ![A]     calling callee ![A, B]      → NG (missing B)
#   caller (pure)   calling callee ![A]         → NG
#   caller (any)      calling unannotated         → OK (pure)
#
# See lsp/effects.pm for an LSP diagnostic showcase.

say "";
say "── Pure function (no effects) ─────────────────";

sub pure_add :sig((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

say "  pure_add(2, 3) = ", pure_add(2, 3);
