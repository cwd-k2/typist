#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist;

# ═══════════════════════════════════════════════════════════
#  08 — Gradual Typing
#
#  Typist uses gradual typing: the density of annotations
#  determines how strictly static checks are enforced.
#
#    Fully annotated    → all checks (types + effects)
#    Partially annotated → only checkable parts verified
#    Unannotated         → treated as (Any...) -> Any (pure)
#
#  This lets you incrementally adopt types in an existing
#  codebase — annotate what matters, leave the rest.
#
#  Note: this example uses static-only mode (no -runtime)
#  to focus on CHECK-phase behavior.
# ═══════════════════════════════════════════════════════════

# ── 1. Fully Annotated ────────────────────────────────────
#
# All params and return type known → full checking.

sub greet :sig((Str) -> Str) ($name) {
    "Hello, $name!";
}

sub add :sig((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

# Return type propagates into variable initialization:
# greet() returns Str, so $msg is typed as Str at the call site.
my $msg :sig(Str) = greet("Alice");
say $msg;

# ── 2. Variable Symbol Resolution ────────────────────────
#
# Static checker resolves annotated variable types at call sites.

sub loud :sig((Str) -> Str) ($s) {
    uc($s);
}

# $msg was declared :sig(Str), loud() accepts Str → OK
say loud($msg);

# ── 3. Nested Calls ──────────────────────────────────────
#
# Return types chain through call nesting.

sub double :sig((Int) -> Int) ($x) {
    $x * 2;
}

# double(3) → Int, add(Int, Int) → Int — all resolved statically
say "3*2 + 10 = ", add(double(3), 10);

# ── 4. Partially Annotated ────────────────────────────────
#
# Only some params annotated, or return type unknown.
# The known parts are checked; the unknown parts are skipped.

# Any return type — params are still checked, but return
# type is unknown to callers.
sub compute :sig((Int) -> Any) ($n) {
    $n * $n;
}

# Return type Any → assignment check skipped (no false positive)
my $result :sig(Int) = compute(5);
say "5^2 = $result";

# ── 5. Unannotated Functions ─────────────────────────────
#
# No annotations at all → (Any...) -> Any (pure)
# Type checks skip; effect treated as pure (no constraint).
# This follows gradual typing: no annotation = no restriction.

sub helper ($x) {
    $x;
}

# Return type is Any → assignment check skipped
my $val :sig(Int) = helper(42);
say "helper: $val";

# ── 6. Flow Typing (Inferred Variables) ──────────────────
#
# When a fully-annotated function's return type is known,
# Typist infers the type of the variable it flows into —
# even without an explicit :Type annotation.

sub format_name :sig((Str) -> Str) ($name) {
    "[$name]";
}

# $formatted has no :Type, but Typist infers Str from
# format_name's return type. Hover shows: $formatted: Str
my $formatted = format_name("Alice");

# loud() accepts Str, $formatted is inferred as Str → OK
say loud($formatted);

# Literal initializers also infer types:
my $count = 42;        # inferred as Int
my $label = "hello";   # inferred as Str

# $count can be passed to Int-expecting functions
say "doubled: ", add(double($count), $count);

# ── 7. Type Narrowing ────────────────────────────────────
#
# defined($x) in an if-condition narrows Maybe[T] to T.

sub safe_length :sig((Maybe[Str]) -> Int) ($s) {
    if (defined($s)) {
        # Inside: $s narrowed from Maybe[Str] to Str
        length($s);
    } else {
        0;
    }
}

say "safe_length('hi'):   ", safe_length("hi");
say "safe_length(undef):  ", safe_length(undef);

# ── 8. Truthiness Narrowing ─────────────────────────────
#
# `if ($x)` narrows Maybe[T] by removing Undef from the union.
# Simpler than `defined($x)` but achieves the same effect.

sub display_name :sig((Maybe[Str]) -> Str) ($name) {
    if ($name) {
        # Inside: $name narrowed from Maybe[Str] to Str
        "Name: $name";
    } else {
        "Anonymous";
    }
}

say display_name("Bob");
say display_name(undef);

# ── 9. Early Return Narrowing ───────────────────────────
#
# `return ... unless defined($x)` narrows $x to T for
# the rest of the function body (after the guard).

sub greet_customer :sig((Maybe[Str]) -> Str) ($name) {
    return "Hello, stranger!" unless defined($name);
    # After early return: $name is narrowed to Str
    "Hello, $name! Welcome back.";
}

say greet_customer("Alice");
say greet_customer(undef);

# ── 10. Else-Block Inverse Narrowing ────────────────────
#
# The else-block gets the inverse narrowing:
# if defined($x) narrows to T in then-block,
# the else-block knows $x is Undef.

sub format_or_default :sig((Maybe[Int]) -> Str) ($n) {
    if (defined($n)) {
        # then: $n is Int
        "Value: $n";
    } else {
        # else: $n is Undef — inverse narrowing
        "No value provided";
    }
}

say format_or_default(42);
say format_or_default(undef);

# ── Summary ───────────────────────────────────────────────
#
# ┌─────────────────────┬──────────────────┬──────────────────┐
# │ Annotation Level    │ Type Checking    │ Effect Checking  │
# ├─────────────────────┼──────────────────┼──────────────────┤
# │ Fully annotated     │ All checks       │ Effects verified │
# │ Any return type     │ Params checked   │ Pure (no effects)│
# │ Completely unannot. │ Any (skip)       │ Pure (no constr.) │
# └─────────────────────┴──────────────────┴──────────────────┘
#
# Flow Typing:
#   my $r = f("str")  → $r inferred as Str (if f :: Str -> Str)
#   my $x = 42        → $x inferred as Int from literal
#
# Type Narrowing:
#   if (defined($x))  → $x narrowed from Maybe[T] to T
#   if ($x)           → truthiness narrows Maybe[T] to T
#   return unless defined($x) → early return narrows for rest of body
#   if/else           → else-block gets inverse narrowing
