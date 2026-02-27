#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL;

# ── Gradual Typing in Typist ────────────────────
#
# Typist uses gradual typing: the density of annotations determines
# the strictness of static checks.
#
#   Fully annotated   → all checks enforced
#   Partially annotated → only checkable parts verified
#   Unannotated        → treated as (Any...) -> Any ! Eff(*)

# ── 1. Fully Annotated: Return Type Propagation ─

sub greet :Params(Str) :Returns(Str) ($name) {
    "Hello, $name!";
}

# greet() is known to return Str → assigned to Str, OK
my $msg :Type(Str) = greet("Alice");
say $msg;

# ── 2. Variable Symbol Resolution ───────────────

sub loud :Params(Str) :Returns(Str) ($s) {
    uc($s);
}

# $msg is declared :Type(Str), loud() accepts Str → OK
say loud($msg);

# ── 3. Nested Function Calls ────────────────────

sub double :Params(Int) :Returns(Int) ($x) {
    $x * 2;
}

sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
    $a + $b;
}

# double(3) returns Int, add(Int, Int) → OK
say "3*2 + 10 = ", add(double(3), 10);

# ── 4. Partially Annotated (Params only) ────────

# :Params but no :Returns → return type is unknown, not Any.
# The function is still tracked for param checking.
sub compute :Params(Int) ($n) {
    $n * $n;
}

# Return type unknown → skipped (no false positive)
my $result :Type(Int) = compute(5);
say "5^2 = $result";

# ── 5. Unannotated Function ─────────────────────

# No annotations at all → (Any...) -> Any ! Eff(*)
# Type checks skip this function's return value.
# Effect checks flag annotated callers that call this.
sub helper ($x) {
    $x;
}

# Return type is Any → assignment check skipped
my $val :Type(Int) = helper(42);
say "helper: $val";

# ── 6. Effect Interaction with Gradual Typing ───

BEGIN {
    effect Console => +{
        writeLine => Func(Str, returns => Void),
    };
}

# Annotated with :Eff(Console) — effect is tracked
sub print_msg :Params(Str) :Eff(Console) ($s) {
    say $s;
}

# Annotated function (:Params/:Returns) with no :Eff → pure.
# Calling another pure annotated function is fine.
sub format_msg :Params(Str) :Returns(Str) ($s) {
    ">> $s <<";
}

say format_msg("pure function");
print_msg("effectful function");

# ── Summary ─────────────────────────────────────
#
# | Annotation Level       | Type Checking        | Effect Checking        |
# |------------------------|----------------------|------------------------|
# | Fully annotated        | All checks enforced  | Effects verified       |
# | Params only (no Ret)   | Params checked       | Pure (no effects)      |
# | Completely unannotated | Any (skip)           | Eff(*) (any effect)    |
