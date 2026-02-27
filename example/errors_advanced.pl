#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist;

# ═══════════════════════════════════════════════════
#  Advanced Type Errors — Generics, newtypes, literals
# ═══════════════════════════════════════════════════

say "── Literal Type Violations ───────────────────";

# Only the exact value 42 is accepted
my $answer :Type(42) = 42;
eval { $answer = 43 };
say "42 <- 43:       $@" if $@;

eval { $answer = 0 };
say "42 <- 0:        $@" if $@;

# String literal type
my $status :Type("ok" | "error") = "ok";
eval { $status = "warning" };
say '"ok"|"error" <- "warning":  ' . $@  if $@;

eval { $status = 0 };
say '"ok"|"error" <- 0:          ' . $@ if $@;

say "";
say "── Newtype Violations ────────────────────────";

BEGIN {
    newtype UserId  => 'Int';
    newtype OrderId => 'Int';
}

# Newtype rejects raw values (must be wrapped)
my $uid :Type(UserId) = UserId(42);
eval { $uid = 42 };
say "UserId <- raw Int:     $@" if $@;

eval { $uid = UserId("hello") };
say "UserId <- UserId(Str): $@" if $@;

# Newtypes with same inner type are NOT interchangeable
my $oid = OrderId(99);
eval { $uid = $oid };
say "UserId <- OrderId:     $@" if $@;

# Accessing inner value requires unwrap
say "unwrap(UserId(42)): ", unwrap(UserId(42));

say "";
say "── Bounded Quantification Violations ─────────";

sub double :Generic(T: Num) :Params(T) :Returns(T) ($x) {
    $x * 2;
}

say "double(5):   ", double(5);
say "double(1.5): ", double(1.5);

# Str is not <: Num
eval { double("five") };
say "double('five'):  $@" if $@;

# ArrayRef is not <: Num
eval { double([10]) };
say "double([10]):    $@" if $@;

sub clamp :Generic(T: Int) :Params(T, T, T) :Returns(T) ($val, $lo, $hi) {
    $val < $lo ? $lo : $val > $hi ? $hi : $val;
}

say "clamp(5,0,10): ", clamp(5, 0, 10);

# Float is not <: Int
eval { clamp(3.14, 0, 10) };
say "clamp(3.14,...):  $@" if $@;

say "";
say "── Type Class Violations ─────────────────────";

BEGIN {
    typeclass 'Eq', 'T',
        eq => 'CodeRef[T, T -> Bool]';

    instance 'Eq', 'Int',
        eq => sub ($a, $b) { $a == $b ? 1 : 0 };

    instance 'Eq', 'Str',
        eq => sub ($a, $b) { $a eq $b ? 1 : 0 };
}

say "Eq::eq(1, 1):         ", Eq::eq(1, 1);
say "Eq::eq('a', 'b'):     ", Eq::eq("a", "b");

# No Eq instance for ArrayRef
eval { Eq::eq([1], [1]) };
say "Eq::eq([1],[1]):      $@" if $@;

say "";
say "── Generic + TypeClass Constraint Violations ─";

# T must have an Eq instance
sub all_equal :Generic(T: Eq) :Params(T, T) :Returns(Bool) ($a, $b) {
    Eq::eq($a, $b);
}

say "all_equal(1, 1):     ", all_equal(1, 1);
say "all_equal('x','y'):  ", all_equal("x", "y");

# Float/ArrayRef have no Eq instance
eval { all_equal(1.5, 1.5) };
say "all_equal(1.5,1.5):  $@" if $@;

say "";
say "── Recursive Type Violations ─────────────────";

BEGIN {
    typedef JsonValue =>
        'Str | Num | Bool | Undef | ArrayRef[JsonValue] | HashRef[Str, JsonValue]';
}

# Valid JSON structures
my $json :Type(JsonValue) = +{ name => "Alice", scores => [100, 95] };

# CodeRef is not a valid JsonValue
eval { $json = sub { 1 } };
say "JsonValue <- CodeRef:   $@" if $@;

# Regexp ref is not a valid JsonValue
eval { $json = qr/pattern/ };
say "JsonValue <- Regexp:    $@" if $@;

say "";
say "── Optional Struct Field Violations ──────────";

BEGIN {
    typedef Config => '{ host => Str, port => Int, debug? => Bool }';
}

# Required fields present, optional omitted — ok
my $cfg :Type(Config) = +{ host => "localhost", port => 8080 };

# Missing required field
eval { $cfg = +{ host => "localhost" } };
say "Config w/o port:        $@" if $@;

# Optional field present but wrong type
eval { $cfg = +{ host => "localhost", port => 8080, debug => "yes" } };
say "Config debug=Str:       $@" if $@;

# Wrong type on required field
eval { $cfg = +{ host => 3000, port => 8080 } };
say "Config host=Int:        $@" if $@;

say "";
say "── Intersection of Errors ────────────────────";

# Multi-layer nesting: ArrayRef of structs
BEGIN {
    typedef UserList => 'ArrayRef[{ name => Str, age => Int }]';
}

my $users :Type(UserList) = [+{ name => "Alice", age => 30 }];

# One invalid element contaminates the whole array
eval { $users = [+{ name => "Bob", age => 25 }, +{ name => "Carol" }] };
say "UserList <- missing age:  $@" if $@;

eval { $users = "not an array" };
say "UserList <- Str:          $@" if $@;
