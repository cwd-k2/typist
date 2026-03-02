#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  03 — Generics
#
#  Parametric polymorphism: type variables, bounded
#  quantification, and multi-parameter generics.
#
#  <T>         — unconstrained type variable
#  <T: Num>    — T must be a subtype of Num
#  <T, U>      — multiple type parameters
# ═══════════════════════════════════════════════════════════

# ── Basic Generic Functions ───────────────────────────────
#
# <T> introduces a type variable. The static checker infers T
# from the call site via unification; runtime validates
# concrete types at the boundary.

sub identity :sig(<T>(T) -> T) ($x) {
    $x;
}

sub first :sig(<T>(ArrayRef[T]) -> T) ($arr) {
    $arr->[0];
}

say "identity(42):      ", identity(42);
say "identity('hello'): ", identity("hello");

say "first([10,20,30]):       ", first([10, 20, 30]);
say "first(['a','b','c']):    ", first(["a", "b", "c"]);

# ── Multi-Parameter Generics ─────────────────────────────
#
# <T, U> declares independent type variables.

sub pair :sig(<T, U>(T, U) -> Tuple[T, U]) ($a, $b) {
    [$a, $b];
}

sub swap :sig(<T, U>(Tuple[T, U]) -> Tuple[U, T]) ($t) {
    [$t->[1], $t->[0]];
}

my $p = pair(42, "hello");
say "pair: ($p->[0], $p->[1])";

my $s = swap($p);
say "swap: ($s->[0], $s->[1])";

# ── Bounded Quantification ───────────────────────────────
#
# <T: Num> constrains T to subtypes of Num (Int, Num itself).
# Str, ArrayRef, etc. are rejected at the call site.

sub add :sig(<T: Num>(T, T) -> T) ($a, $b) {
    $a + $b;
}

sub mul :sig(<T: Num>(T, T) -> T) ($a, $b) {
    $a * $b;
}

say "add(3, 4):     ", add(3, 4);       # Int <: Num — ok
say "add(1.5, 2.5): ", add(1.5, 2.5);   # Num <: Num — ok
say "mul(6, 7):     ", mul(6, 7);

eval { add("x", "y") };
say "add('x','y'):  $@" if $@;

eval { add([1], [2]) };
say "add([1],[2]):  $@" if $@;

# <T: Int> — even stricter: only Int is accepted.
sub increment :sig(<T: Int>(T) -> T) ($x) {
    $x + 1;
}

say "increment(10): ", increment(10);

eval { increment(3.14) };
say "increment(3.14): $@" if $@;

# ── Generics with Composite Types ────────────────────────

sub head_or_default :sig(<T>(ArrayRef[T], T) -> T) ($arr, $default) {
    @$arr ? $arr->[0] : $default;
}

say "head_or_default([1,2], 0):    ", head_or_default([1, 2], 0);
say "head_or_default([], 'none'):  ", head_or_default([], "none");

sub zip :sig(<T, U>(ArrayRef[T], ArrayRef[U]) -> ArrayRef[Tuple[T, U]]) ($xs, $ys) {
    my $len = @$xs < @$ys ? @$xs : @$ys;
    [ map { [$xs->[$_], $ys->[$_]] } 0 .. $len - 1 ];
}

my $zipped = zip([1, 2, 3], ["a", "b", "c"]);
for my $pair (@$zipped) {
    say "  ($pair->[0], $pair->[1])";
}
