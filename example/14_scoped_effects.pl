#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;

# ═══════════════════════════════════════════════════════════
#  14 — Scoped Effects
#
#  Identity-based effect dispatch with capability tokens:
#
#    my $counter = scoped 'State[Int]';
#    $counter->put(42);
#    $counter->get();    # 42
#
#  Unlike name-based effects (State::get()), scoped effects
#  let you have multiple independent instances of the same
#  effect type.
# ═══════════════════════════════════════════════════════════

# ── Parameterized Effect Definition ─────────────────────
#
# effect 'Name[S]' => +{ ... } defines a generic effect.
# S is the type parameter, instantiated at use sites.

BEGIN {
    effect 'State[S]' => +{
        get => '() -> S',
        put => '(S) -> Void',
    };

    effect Logger => +{
        log => '(Str) -> Void',
    };
}

# ── Creating Scoped Capabilities ────────────────────────
#
# scoped 'Effect[Type]' creates a capability token.
# Each token has a unique identity for handler dispatch.

say "── Scoped creation ────────────────────────────";

my $counter = scoped 'State[Int]';
say "  counter: ", ref $counter;
say "  effect_name: ", $counter->effect_name;
say "  base_name: ", $counter->base_name;

# ── Basic Scoped Handler ────────────────────────────────
#
# handle { body } $ref => +{ ... }
# Uses identity dispatch instead of name-based dispatch.

say "";
say "── Basic scoped handler ───────────────────────";

my $state = 0;
my $result = handle {
    $counter->put(42);
    $counter->get();
} $counter => +{
    get => sub { $state },
    put => sub ($v) { $state = $v },
};

say "  result: $result";    # 42
say "  state: $state";      # 42

# ── Independent Instances ───────────────────────────────
#
# Two scoped effects of the same type work independently.
# This is impossible with name-based effects.

say "";
say "── Independent instances ──────────────────────";

my $x = scoped 'State[Int]';
my $y = scoped 'State[Int]';
my ($sx, $sy) = (0, 0);

handle {
    handle {
        $x->put(100);
        $y->put(200);

        say "  x = ", $x->get();    # 100
        say "  y = ", $y->get();    # 200
    } $y => +{
        get => sub { $sy },
        put => sub ($v) { $sy = $v },
    };
} $x => +{
    get => sub { $sx },
    put => sub ($v) { $sx = $v },
};

say "  final x state: $sx";    # 100
say "  final y state: $sy";    # 200

# ── Mixed Name-Based and Scoped ─────────────────────────
#
# Scoped and name-based handlers coexist in the same block.

say "";
say "── Mixed dispatch ─────────────────────────────";

my $acc = scoped 'State[Int]';
my $acc_state = 0;
my @log;

handle {
    Logger::log("accumulating");
    $acc->put(10);
    $acc->put($acc->get() + 5);
    Logger::log("result: " . $acc->get());
} $acc => +{
    get => sub { $acc_state },
    put => sub ($v) { $acc_state = $v },
},
Logger => +{
    log => sub ($msg) { push @log, $msg; say "  [log] $msg" },
};

say "  final: $acc_state";                         # 15
say "  logs: ", join(", ", @log);                  # accumulating, result: 15

# ── Exception Cleanup ──────────────────────────────────
#
# Scoped handlers are cleaned up on exceptions,
# just like name-based handlers.

say "";
say "── Exception cleanup ─────────────────────────";

my $ephemeral = scoped 'State[Int]';
eval {
    handle {
        $ephemeral->put(999);
        die "boom\n";
    } $ephemeral => +{
        get => sub { 0 },
        put => sub ($) { },
    };
};
say "  exception: $@";

eval { $ephemeral->get() };
say "  after cleanup: ", ($@ =~ /No scoped handler/ ? "handler gone (correct)" : "unexpected: $@");

# ── Scoped + Exn ────────────────────────────────────────
#
# Combining scoped effects with exception recovery.

say "";
say "── Scoped + Exn recovery ─────────────────────";

my $careful = scoped 'State[Int]';
my $careful_state = 0;

my $recovered = handle {
    $careful->put(5);
    die "oops\n";
    $careful->put(99);    # unreachable
} $careful => +{
    get => sub { $careful_state },
    put => sub ($v) { $careful_state = $v },
},
Exn => +{
    throw => sub ($err) { "recovered from: $err" },
};

say "  state before error: $careful_state";    # 5
say "  $recovered";                            # recovered from: oops
