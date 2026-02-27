#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL;

# ── Generic Functions ─────────────────────────────

sub first :Generic(T) :Params(ArrayRef[T]) :Returns(T) ($arr) {
    $arr->[0];
}

sub pair :Generic(T, U) :Params(T, U) :Returns(ArrayRef[Any]) ($a, $b) {
    [$a, $b];
}

say "first int:  ", first([10, 20, 30]);
say "first str:  ", first(["hello", "world"]);

my $p = pair(42, "answer");
say "pair: [$p->[0], $p->[1]]";

# ── Parameterized Types ──────────────────────────

my $nums :Type(ArrayRef[Int]) = [1, 2, 3];
my $dict :Type(HashRef[Str, Int]) = { alice => 1, bob => 2 };

say "nums: @$nums";
say "dict keys: ", join(", ", sort keys %$dict);

# ── Union Types ──────────────────────────────────

my $id :Type(Int | Str) = 42;
say "id (int): $id";

$id = "ABC-123";
say "id (str): $id";

eval { $id = [1, 2] };
say "Caught: $@" if $@;
