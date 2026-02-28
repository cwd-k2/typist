#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  01 — Foundations
#
#  Typist's basic building blocks: type aliases, typed
#  variables, and typed subroutines.
#
#    use Typist;           # static-only  (CHECK + LSP)
#    use Typist -runtime;  # + runtime enforcement (Tie + wrap)
# ═══════════════════════════════════════════════════════════

# ── Type Aliases ──────────────────────────────────────────
#
# typedef creates a named alias for a type expression.
# Place in BEGIN so CHECK-phase analysis can resolve them.

BEGIN {
    typedef Name => Str;
    typedef Age  => Int;
}

# Aliases are structural — Name is interchangeable with Str.
my $name :Type(Name) = "Alice";
my $age  :Type(Age)  = 30;

say "name=$name  age=$age";

# ── Typed Variables ───────────────────────────────────────
#
# :Type(T) enforces the type on every assignment.
# Runtime mode validates via Tie::Scalar on STORE.

my $score :Type(Int) = 100;
$score = 95;                    # ok: Int <- Int

eval { $score = "high" };       # ng: "high" is not numeric
say "Int <- Str:    $@" if $@;

eval { $score = 3.14 };         # ng: Float is not Int
say "Int <- Num:    $@" if $@;

eval { $score = undef };        # ng: undef is not Int
say "Int <- undef:  $@" if $@;

# Maybe[T] = T | Undef — explicitly nullable.
my $email :Type(Maybe[Str]) = undef;
$email = 'alice@example.com';   # ok: Str
$email = undef;                 # ok: Undef

eval { $email = [1, 2] };       # ng: ArrayRef is not Str | Undef
say "Maybe[Str] <- ArrayRef:  $@" if $@;

# ── Typed Subroutines ────────────────────────────────────
#
# :Type((Params) -> Return) annotates the full signature.
# Runtime mode wraps the sub to check args and return value.

sub greet :Type((Str) -> Str) ($who) {
    "Hello, $who!";
}

sub add :Type((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

say greet("Bob");               # "Hello, Bob!"
say "2 + 3 = ", add(2, 3);     # 5

# Argument type violations
eval { add("x", 1) };
say "add('x', 1):  $@" if $@;

eval { add(1, []) };
say "add(1, []):   $@" if $@;

# Arity is also checked at the static level.
# add(1) → ArityMismatch in CHECK-phase diagnostics.

# ── Multi-Argument Functions ──────────────────────────────

sub clamp :Type((Int, Int, Int) -> Int) ($val, $lo, $hi) {
    $val < $lo ? $lo : $val > $hi ? $hi : $val;
}

say "clamp(15, 0, 10) = ", clamp(15, 0, 10);   # 10
say "clamp(-5, 0, 10) = ", clamp(-5, 0, 10);   # 0

# ── Aliases Compose ───────────────────────────────────────

BEGIN {
    typedef Greeting => Str;
}

sub make_greeting :Type((Name, Age) -> Greeting) ($n, $a) {
    "$n is $a years old";
}

say make_greeting("Carol", 25);
