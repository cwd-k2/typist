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

sub greet :Type((Str) -> Str) ($name) {
    "Hello, $name!";
}

# greet() is known to return Str → assigned to Str, OK
my $msg :Type(Str) = greet("Alice");
say $msg;

# ── 2. Variable Symbol Resolution ───────────────

sub loud :Type((Str) -> Str) ($s) {
    uc($s);
}

# $msg is declared :Type(Str), loud() accepts Str → OK
say loud($msg);

# ── 3. Nested Function Calls ────────────────────

sub double :Type((Int) -> Int) ($x) {
    $x * 2;
}

sub add :Type((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

# double(3) returns Int, add(Int, Int) → OK
say "3*2 + 10 = ", add(double(3), 10);

# ── 4. Partially Annotated (Any return type) ────

# :Type((Int) -> Any) → return type is Any, effectively unknown.
# The function is still tracked for param checking.
sub compute :Type((Int) -> Any) ($n) {
    $n * $n;
}

# Return type Any → skipped (no false positive)
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

# ── 6. Flow Typing: Inferred Variable Types ────

# When f :: Str -> Str, my $result = f("str") infers $result as Str
# without any explicit type annotation.

sub format_name :Type((Str) -> Str) ($name) {
    "[$name]";
}

# $formatted has no :Type annotation, but Typist infers it as Str
# from format_name's return type.
my $formatted = format_name("Alice");

# This works: loud() accepts Str, and $formatted is inferred as Str
say loud($formatted);

# Similarly, literal initializers infer types:
my $count = 42;        # inferred as Int
my $label = "hello";   # inferred as Str

# $count can be passed to functions expecting Int
say "doubled: ", add(double($count), $count);

# ── 7. Effect Interaction with Gradual Typing ───

BEGIN {
    effect Console => +{
        writeLine => Func(Str, returns => Void),
    };
}

# Annotated with effect — effect is tracked
# Return type is Any (not Void) since say returns 1; Void would reject it.
sub print_msg :Type((Str) -> Any ! Console) ($s) {
    say $s;
}

# Annotated function without effect → pure.
# Calling another pure annotated function is fine.
sub format_msg :Type((Str) -> Str) ($s) {
    ">> $s <<";
}

say format_msg("pure function");
print_msg("effectful function");

# ── Summary ─────────────────────────────────────
#
# | Annotation Level       | Type Checking        | Effect Checking        |
# |------------------------|----------------------|------------------------|
# | Fully annotated        | All checks enforced  | Effects verified       |
# | Any return type        | Params checked       | Pure (no effects)      |
# | Completely unannotated | Any (skip)           | Eff(*) (any effect)    |
#
# Flow Typing:
#   my $result = f("str")  →  $result is inferred as Str (if f :: Str -> Str)
#   my $x = 42             →  $x is inferred as Int from literal
#
# LSP Hover:
#   Unannotated function  →  sub helper(Any) -> Any !Eff(*)
#   Inferred variable     →  $result: Str (inferred)
