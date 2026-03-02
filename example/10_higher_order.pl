#!/usr/bin/env perl
use v5.40;
use lib 'lib';
BEGIN { $ENV{TYPIST_CHECK_QUIET} = 1 }  # LSP provides diagnostics
use Typist -runtime;
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  10 — Higher-Order Function Type Inference
#
#  Typist's static inference propagates types through
#  higher-order patterns: match arm callbacks receive
#  variant inner types, and map/grep/sort track element
#  types via $_.
# ═══════════════════════════════════════════════════════════

# ── ADT Definitions ──────────────────────────────────────

datatype 'Result[T]' =>
    Ok  => '(T)',
    Err => '(Str)';

datatype 'Option[T]' =>
    Some => '(T)',
    None => '()';

datatype Shape =>
    Circle    => '(Int)',
    Rectangle => '(Int, Int)';

# ── Match with Typed Variant Params ──────────────────────
#
# When matching on Result[Int], the Ok arm's $val is known
# to be Int, and the Err arm's $msg is known to be Str.

say "── match: Result[Int] ──────────────────";

my $result :sig(Result[Int]) = Ok(42);

my $output :sig(Str) = match $result,
    Ok  => sub ($val) { "Success: $val" },
    Err => sub ($msg) { "Error: $msg" };

say $output;

# ── Match: Option[Str] ──────────────────────────────────

say "\n── match: Option[Str] ──────────────────";

my $name :sig(Option[Str]) = Some("Alice");

my $greeting :sig(Str) = match $name,
    Some => sub ($n)  { "Hello, $n!" },
    None => sub       { "Hello, stranger!" };

say $greeting;

# ── Match: Non-parameterized ADT ────────────────────────

say "\n── match: Shape ────────────────────────";

my $shape :sig(Shape) = Rectangle(3, 4);

my $area :sig(Int) = match $shape,
    Circle    => sub ($r)     { $r * $r },
    Rectangle => sub ($w, $h) { $w * $h };

say "Area: $area";

# ── Higher-Order Functions with Callbacks ────────────────

say "\n── HOF: apply ──────────────────────────";

sub apply :sig(((Int) -> Int, Int) -> Int) ($f, $x) {
    $f->($x);
}

my $doubled :sig(Int) = apply(sub ($n) { $n * 2 }, 21);
say "apply(double, 21) = $doubled";

sub transform :sig(((Str) -> Str, Str) -> Str) ($f, $s) {
    $f->($s);
}

my $upper :sig(Str) = transform(sub ($s) { uc($s) }, "hello");
say "transform(uc, hello) = $upper";

# ── Map/Grep with Typed $_ ──────────────────────────────

say "\n── map/grep ────────────────────────────";

my $nums :sig(ArrayRef[Int]) = [1, 2, 3, 4, 5];

my $squares :sig(ArrayRef[Num]) = [map { $_ * $_ } @$nums];
say "squares: @$squares";

my $evens :sig(ArrayRef[Int]) = [grep { $_ % 2 == 0 } @$nums];
say "evens: @$evens";

my $sorted :sig(ArrayRef[Int]) = [sort { $a <=> $b } reverse @$nums];
say "sorted: @$sorted";

# ── Composition ──────────────────────────────────────────

say "\n── composition ─────────────────────────";

my $results :sig(ArrayRef[Result[Int]]) = [Ok(1), Ok(2), Err("nope"), Ok(4)];

my @values;
for my $r (@$results) {
    match $r,
        Ok  => sub ($v) { push @values, $v },
        Err => sub ($m) { say "  skipping: $m" };
}
say "collected: @values";

say "\nDone.";
