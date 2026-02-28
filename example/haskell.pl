#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

# ── Newtype (Nominal Types) ─────────────────────

# Like Haskell's `newtype UserId = UserId Int`.
# Same inner type, distinct identity — no structural subtyping.

BEGIN {
    newtype UserId  => Int;
    newtype OrderId => Int;
}

my $uid = UserId(42);
my $oid = OrderId(99);

say "UserId:  ", unwrap($uid);
say "OrderId: ", unwrap($oid);

eval { UserId("hello") };
say "Caught: $@" if $@;

# ── Literal Types ───────────────────────────────

# Singleton types: only the exact value is accepted.

my $answer :Type(42) = 42;
say "answer: $answer";

eval { $answer = 43 };
say "Caught: $@" if $@;

my $tag :Type("ok" | "error") = "ok";
say "tag: $tag";

$tag = "error";
say "tag: $tag";

# ── Recursive Types ─────────────────────────────

# Self-referential typedef — productive recursion through constructors.

BEGIN {
    typedef JsonValue =>
        Str | Num | Bool | Undef | ArrayRef(Alias('JsonValue')) | HashRef(Str, Alias('JsonValue'));
}

my $json :Type(JsonValue) = +{
    name   => "Alice",
    scores => [100, 95],
    meta   => +{ active => 1 },
};
say "json: valid";

eval { my $bad :Type(JsonValue) = sub {} };
say "Caught: $@" if $@;

# ── Bounded Quantification ──────────────────────

# <T: Num> means T must be <: Num.

sub add_num :Type(<T: Num>(T, T) -> T) ($a, $b) {
    $a + $b;
}

say "3 + 4 = ", add_num(3, 4);
say "1.5 + 2.5 = ", add_num(1.5, 2.5);

eval { add_num("x", "y") };
say "Caught: $@" if $@;

# ── Type Classes ────────────────────────────────

# typeclass defines the interface; instance provides implementations.
# Dispatch is ad-hoc: resolved by inferring the argument type at runtime.

BEGIN {
    typeclass Show => T, +{
        show => Func(T, returns => Str),
    };

    instance Show => Int, +{
        show => sub ($v) { "Int($v)" },
    };

    instance Show => Str, +{
        show => sub ($v) { qq["$v"] },
    };
}

say Show::show(42);
say Show::show("hello");

# ── Superclass Constraints ─────────────────────

# `Ord => 'T: Eq'` means every Ord instance requires an Eq instance.
# Like Haskell's `class Eq a => Ord a where ...`.

BEGIN {
    typeclass Eq => T, +{
        eq => Func(T, T, returns => Bool),
    };

    instance Eq => Int, +{
        eq => sub ($a, $b) { $a == $b ? 1 : 0 },
    };

    typeclass Ord => 'T: Eq', +{
        compare => Func(T, T, returns => Int),
    };

    instance Ord => Int, +{
        compare => sub ($a, $b) { $a <=> $b },
    };
}

say "Eq::eq(1, 1):      ", Eq::eq(1, 1);
say "Ord::compare(1, 2): ", Ord::compare(1, 2);

# ── Higher-Kinded Types ─────────────────────────

# `F: * -> *` declares F as a type constructor (kind * -> *).
# This enables abstractions like Functor over ArrayRef, HashRef, etc.
# Dispatch resolves the instance from the first argument,
# so the container comes first: fmap(F[A], A -> B) -> F[B].

BEGIN {
    typeclass Functor => 'F: * -> *', +{
        fmap => 'CodeRef[F[A], CodeRef[A -> B] -> F[B]]',
    };

    instance Functor => 'ArrayRef', +{
        fmap => sub ($arr, $f) { [map { $f->($_) } @$arr] },
    };
}

my $doubled = Functor::fmap([1, 2, 3], sub ($x) { $x * 2 });
say "fmap (*2) [1,2,3] = [@$doubled]";

my $strings = Functor::fmap([10, 20], sub ($x) { "[$x]" });
say "fmap (show) [10,20] = @$strings";
