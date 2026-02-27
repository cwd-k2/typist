#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL;

# ── Type Aliases ──────────────────────────────────

# typedef in BEGIN so CHECK-phase analysis can see them
BEGIN {
    typedef Name   => Str;
    typedef Age    => Int;
    typedef Person => Struct(name => Str, age => Int);
}

# ── Typed Variables ───────────────────────────────

my $name  :Type(Name) = "Alice";
my $age   :Type(Age)  = 30;
my $score :Type(Maybe[Int]) = undef;

say "name: $name, age: $age, score: ", $score // "(none)";

$score = 95;
say "score: $score";

# ── Typed Subroutines ────────────────────────────

sub greet :Params(Name) :Returns(Str) ($who) {
    "Hello, $who!";
}

sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
    $a + $b;
}

say greet("Bob");
say "2 + 3 = ", add(2, 3);

# ── Error Handling ───────────────────────────────

eval { $age = "young" };
say "Caught: $@" if $@;

eval { add("x", 1) };
say "Caught: $@" if $@;
