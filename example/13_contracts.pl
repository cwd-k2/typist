#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  13 — Contract Programming via Algebraic Effects + Protocol
#
#  Design by Contract as an effect with protocol-enforced
#  state transitions:
#
#    * --[pre]--> Guarded --[post]--> *
#                    ↺ pre, old, inv
#
#  Operations:
#    pre  — precondition  (caller's obligation)
#    old  — snapshot a value for post-condition reference
#    inv  — mid-body invariant check (Eiffel's `check`)
#    post — postcondition (callee's obligation)
#
#  The protocol guarantees at the type level:
#    - pre must precede body execution
#    - old/inv are only valid within the guarded region
#    - post must close the guarded region
#    - ![Contract] (= * -> *) requires both pre and post
#
#  Enforcement strategy is a handler concern.  All checking
#  handlers use die for non-local exit — safe_div(10, 0)
#  never reaches the division.
#
#  ── Eiffel Comparison ──────────────────────────────
#
#  Covered:
#    pre/post/old/check → Contract::{pre,post,old,inv}
#    -check flag        → handler strategy (scoped)
#    static tracking    → ![Contract] + Protocol
#
#  Out of scope (no OOP inheritance in Typist):
#    class invariant    → auto-checked on all public methods
#    contract inherit.  → weaken pre / strengthen post (LSP)
#    loop variant       → termination proof
#    rescue/retry       → exception recovery + re-entry
# ═══════════════════════════════════════════════════════════

# ── Effect Definitions ──────────────────────────────────
#
# Contract ops and their protocol transitions:
#   pre  : * | Guarded → Guarded  (enter/stay in guard)
#   old  : Guarded → Guarded      (snapshot for post)
#   inv  : Guarded → Guarded      (mid-body assertion)
#   post : Guarded → *            (exit guard)
#
# old is the only op that returns a value — (Any) -> Any
# with identity semantics.  The handler can intercept the
# snapshot (e.g., for logging), but must return the value
# since the body depends on it.

BEGIN {
    effect 'Contract', [qw(Guarded)] => +{
        pre  => ['(Any, Str) -> Void', protocol('* | Guarded -> Guarded')],
        old  => ['(Any) -> Any',       protocol('Guarded -> Guarded')],
        inv  => ['(Any, Str) -> Void', protocol('Guarded -> Guarded')],
        post => ['(Any, Str) -> Void', protocol('Guarded -> *')],
    };

    effect State => +{
        get => '() -> Int',
        put => '(Int) -> Void',
    };
}

# ── Handler Strategies ──────────────────────────────────

my $failfast = +{
    pre  => sub ($ok, $msg) { die "Pre-condition failed: $msg\n"  unless $ok },
    old  => sub ($val)      { $val },
    inv  => sub ($ok, $msg) { die "Invariant violated: $msg\n"    unless $ok },
    post => sub ($ok, $msg) { die "Post-condition failed: $msg\n" unless $ok },
};

my $noop = +{
    pre  => sub ($ok, $msg) { },
    old  => sub ($val)      { $val },   # must return — body depends on it
    inv  => sub ($ok, $msg) { },
    post => sub ($ok, $msg) { },
};

# ── Contracted Functions ────────────────────────────────
#
# Protocol: pre → [old] → body → [inv] → post
# ![Contract] = * -> * enforces both pre and post.

sub safe_div :sig((Num, Num) -> Num ![Contract]) ($a, $b) {
    Contract::pre($b != 0, "divisor must not be zero");
    my $r = $a / $b;
    Contract::post(defined($r), "result must be defined");
    $r;
}

sub safe_sqrt :sig((Num) -> Num ![Contract]) ($n) {
    Contract::pre($n >= 0, "input must be non-negative");
    my $r = sqrt($n);
    Contract::post($r >= 0, "result must be non-negative");
    $r;
}

# ── Fail-fast ───────────────────────────────────────────
#
# die on violation → handle's eval catches → handler pop
# → re-raise.  The division in safe_div never executes.

say "── Fail-fast ──────────────────────────────────";

my $div_ok = eval {
    handle { safe_div(10, 2) } Contract => $failfast;
};
say "  safe_div(10, 2) = $div_ok";

my $div_err = eval {
    handle { safe_div(10, 0) } Contract => $failfast;
};
say "  safe_div(10, 0) → caught: $@" unless $div_err;

my $sqrt_ok = eval {
    handle { safe_sqrt(9) } Contract => $failfast;
};
say "  safe_sqrt(9) = $sqrt_ok";

my $sqrt_err = eval {
    handle { safe_sqrt(-4) } Contract => $failfast;
};
say "  safe_sqrt(-4) → caught: $@" unless $sqrt_err;

# ── Collect (batch validation) ──────────────────────────
#
# Same fail-fast handler, different call pattern: each
# operation is individually eval'd, violations accumulated.
# Non-local exit keeps each call safe.

say "── Collect (batch) ────────────────────────────";

my @violations;
for my $op (
    sub { safe_div(10, 0)  },
    sub { safe_sqrt(-4)    },
    sub { safe_sqrt(9)     },
    sub { safe_div(8, 2)   },
) {
    eval { handle { $op->() } Contract => $failfast };
    push @violations, $@ if $@;
}

say "  violations (", scalar @violations, "):";
say "    - $_" for @violations;

# ── No-op (release mode) ───────────────────────────────
#
# Skip all checks.  Analogous to Eiffel's -check none.

say "── No-op (release mode) ──────────────────────";

my $fast = handle {
    safe_div(100, 3);
    safe_sqrt(144);
} Contract => $noop;

say "  safe_sqrt(144) = $fast  (no overhead)";

# ── old: Snapshot for Postconditions ────────────────────
#
# Contract::old captures a value in the guarded region,
# returning it for use in postcondition expressions.
# Eiffel: ensure balance = old balance - amount
# Typist: Contract::post($old_bal - $amount == $bal, ...)
#
# old is the only Contract op that returns a value.
# The handler must preserve identity semantics — the body
# depends on the returned value.

sub deposit :sig((Int) -> Int ![Contract, State]) ($amount) {
    Contract::pre($amount > 0, "amount must be positive");
    my $old_bal = Contract::old(State::get());
    State::put($old_bal + $amount);
    my $bal = State::get();
    Contract::post($bal == $old_bal + $amount, "balance increased by amount");
    $bal;
}

sub withdraw :sig((Int) -> Int ![Contract, State]) ($amount) {
    Contract::pre($amount > 0,            "amount must be positive");
    Contract::pre($amount <= State::get(), "insufficient funds");
    my $old_bal = Contract::old(State::get());
    State::put($old_bal - $amount);
    my $bal = State::get();
    Contract::post($bal == $old_bal - $amount, "balance decreased by amount");
    $bal;
}

say "";
say "── old + Account (Contract + State) ──────────";

my $balance = 0;
my $state_handler = +{
    get => sub        { $balance },
    put => sub ($val) { $balance = $val },
};

my $final = handle {
    handle {
        deposit(100);
        deposit(50);
        withdraw(30);
    } State => $state_handler;
} Contract => $failfast;

say "  final balance: $final";

# Violation: insufficient funds — non-local exit
my $overdraw = eval {
    handle {
        handle {
            withdraw(200);
        } State => $state_handler;
    } Contract => $failfast;
};
say "  withdraw(200) → caught: $@" unless $overdraw;

say "  balance unchanged: $balance";

# ── Invariant + old: Conservation Law ───────────────────
#
# pre → old → body → inv → post
# Protocol enforces the full sequence within Guarded.
#
# transfer checks:
#   pre  — amount positive, source has enough
#   old  — snapshot total funds before mutation
#   inv  — destination non-negative after update
#   post — total funds conserved (old total == new total)

sub transfer :sig((Int, Int, Int) -> Int ![Contract]) ($from, $to, $amount) {
    Contract::pre($amount > 0,      "amount must be positive");
    Contract::pre($from >= $amount, "insufficient source funds");
    my $old_total = Contract::old($from + $to);
    my $new_from = $from - $amount;
    my $new_to   = $to + $amount;
    Contract::inv($new_to >= 0, "destination must not go negative");
    Contract::post($new_from + $new_to == $old_total, "funds conserved");
    $new_to;
}

say "";
say "── Invariant + old (transfer) ────────────────";

my $result = eval {
    handle { transfer(100, 50, 30) } Contract => $failfast;
};
say "  transfer(100, 50, 30) = $result";

my $bad = eval {
    handle { transfer(10, 50, 30) } Contract => $failfast;
};
say "  transfer(10, 50, 30) → caught: $@" unless $bad;
