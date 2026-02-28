#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL;

# ═══════════════════════════════════════════════════
#  Basic Type Errors — Runtime type checking in action
# ═══════════════════════════════════════════════════

say "── Scalar Type Violations ────────────────────";

# Int rejects strings
my $n :Type(Int) = 42;
eval { $n = "hello" };
say "Int <- Str:    $@" if $@;

# Int rejects floats
eval { $n = 3.14 };
say "Int <- Num:    $@" if $@;

# Str rejects references
my $s :Type(Str) = "ok";
eval { $s = [1, 2] };
say "Str <- Array:  $@" if $@;

# Bool rejects arbitrary strings
my $b :Type(Bool) = 1;
eval { $b = "maybe" };
say "Bool <- Str:   $@" if $@;

say "";
say "── Maybe / Undef ─────────────────────────────";

# Maybe[Int] accepts undef and Int, rejects Str
my $m :Type(Maybe[Int]) = undef;
$m = 10;       # ok
eval { $m = "ten" };
say "Maybe[Int] <- Str:  $@" if $@;

# Non-Maybe Int rejects undef
eval { $n = undef };
say "Int <- undef:       $@" if $@;

say "";
say "── Parameterized Type Violations ─────────────";

# ArrayRef[Int] rejects array containing strings
my $nums :Type(ArrayRef[Int]) = [1, 2, 3];
eval { $nums = [1, "two", 3] };
say "ArrayRef[Int] <- [1,'two',3]:  $@" if $@;

# HashRef[Str, Int] rejects non-Int values
my $dict :Type(HashRef[Str, Int]) = +{ a => 1 };
eval { $dict = +{ a => "one" } };
say "HashRef[Str,Int] <- {a=>'one'}:  $@" if $@;

say "";
say "── Union Type Violations ─────────────────────";

# Int | Str rejects references
my $id :Type(Int | Str) = 42;
$id = "ABC";   # ok
eval { $id = [1] };
say "Int|Str <- ArrayRef:  $@" if $@;

# Accepts neither side of the union
eval { $id = +{ x => 1 } };
say "Int|Str <- HashRef:   $@" if $@;

say "";
say "── Struct Type Violations ────────────────────";

BEGIN {
    typedef Person => Struct(name => Str, age => Int);
}

# Valid struct
my $p :Type(Person) = +{ name => "Alice", age => 30 };

# Missing required field
eval { $p = +{ name => "Bob" } };
say "Person w/o age:       $@" if $@;

# Wrong field type
eval { $p = +{ name => "Carol", age => "young" } };
say "Person age=Str:       $@" if $@;

# Extra fields are tolerated, but wrong types are not
eval { $p = +{ name => 42, age => 30 } };
say "Person name=Int:      $@" if $@;

say "";
say "── Function Param Violations ─────────────────";

sub add :Type((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

# Wrong type for param 1
eval { add("x", 1) };
say "add('x', 1):  $@" if $@;

# Wrong type for param 2
eval { add(1, []) };
say "add(1, []):   $@" if $@;

say "";
say "── Function Return Violations ────────────────";

sub bad_return :Type((Int) -> Int) ($x) {
    "not_a_number";
}

eval { bad_return(42) };
say "Returns(Int) -> Str:  $@" if $@;

sub returns_undef :Type((Str) -> Str) ($x) {
    undef;
}

eval { returns_undef("hi") };
say "Returns(Str) -> undef:  $@" if $@;

say "";
say "── Combined Param + Return ───────────────────";

sub format_age :Type((Int) -> Str) ($age) {
    "Age: $age";
}

say "format_age(25): ", format_age(25);  # ok

eval { format_age("old") };
say "format_age('old'):  $@" if $@;
