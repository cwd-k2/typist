#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  06 — Type Classes
#
#  Ad-hoc polymorphism: typeclass defines an interface,
#  instance provides implementations, and dispatch resolves
#  at runtime by the argument's type.
#
#  Also: superclass constraints, multi-parameter type classes,
#  and higher-kinded types (Functor).
# ═══════════════════════════════════════════════════════════

# ── Basic Type Class ──────────────────────────────────────
#
# typeclass Name => TypeVar, +{ method => '(T) -> ReturnType' }
# instance Name => ConcreteType, +{ method => sub { ... } }
#
# Dispatch namespace: Name::method(value)

BEGIN {
    typeclass Show => 'T', +{
        show => '(T) -> Str',
    };

    instance Show => Int, +{
        show => sub ($v) { "Int($v)" },
    };

    instance Show => Str, +{
        show => sub ($v) { qq["$v"] },
    };

    instance Show => Bool, +{
        show => sub ($v) { $v ? "True" : "False" },
    };
}

say Show::show(42);         # Int(42)
say Show::show("hello");    # "hello"
say Show::show(1);          # depends on dispatch — Int wins for 1

# No instance for ArrayRef
eval { Show::show([1, 2]) };
say "Show::show([]):  $@" if $@;

# ── Multiple Methods ──────────────────────────────────────

BEGIN {
    typeclass Eq => 'T', +{
        eq  => '(T, T) -> Bool',
        neq => '(T, T) -> Bool',
    };

    instance Eq => Int, +{
        eq  => sub ($a, $b) { $a == $b ? 1 : 0 },
        neq => sub ($a, $b) { $a != $b ? 1 : 0 },
    };

    instance Eq => Str, +{
        eq  => sub ($a, $b) { $a eq $b ? 1 : 0 },
        neq => sub ($a, $b) { $a ne $b ? 1 : 0 },
    };
}

say "Eq::eq(1, 1):      ", Eq::eq(1, 1);       # 1
say "Eq::eq('a', 'b'):  ", Eq::eq("a", "b");   # 0
say "Eq::neq(1, 2):     ", Eq::neq(1, 2);      # 1

# ── Superclass Constraints ────────────────────────────────
#
# 'T: Eq' means: to define an Ord instance for T,
# T must already have an Eq instance.

BEGIN {
    typeclass Ord => 'T: Eq', +{
        compare => '(T, T) -> Int',
    };

    instance Ord => Int, +{
        compare => sub ($a, $b) { $a <=> $b },
    };

    instance Ord => Str, +{
        compare => sub ($a, $b) { $a cmp $b },
    };
}

say "Ord::compare(1, 2):     ", Ord::compare(1, 2);      # -1
say "Ord::compare('b', 'a'): ", Ord::compare("b", "a");  # 1

# ── Multi-Parameter Type Classes ──────────────────────────
#
# typeclass Name => 'T, U' — two type variables.
# Dispatch resolves from the first argument's type.

BEGIN {
    typeclass Serialize => 'T, U', +{
        serialize => '(T, U) -> Str',
    };

    instance Serialize => 'Int, Str', +{
        serialize => sub ($n, $fmt) { sprintf($fmt, $n) },
    };
}

say "serialize(42, '%04d'): ", Serialize::serialize(42, "%04d");

# ── Higher-Kinded Types ──────────────────────────────────
#
# 'F: * -> *' declares F as a type constructor (kind * -> *).
# F[A] applies F to A, so ArrayRef[A] is the concrete type.
# The container comes first for dispatch: fmap(F[A], A -> B)

BEGIN {
    typeclass Functor => 'F: * -> *', +{
        fmap => 'CodeRef[F[A], CodeRef[A -> B] -> F[B]]',
    };

    instance Functor => 'ArrayRef', +{
        fmap => sub ($arr, $f) { [map { $f->($_) } @$arr] },
    };
}

my $doubled = Functor::fmap([1, 2, 3], sub ($x) { $x * 2 });
say "fmap (*2) [1,2,3]:  [@$doubled]";

my $strings = Functor::fmap([10, 20, 30], sub ($x) { "[$x]" });
say "fmap (show) [10,20,30]:  @$strings";

# Chaining fmaps
my $result = Functor::fmap(
    Functor::fmap([1, 2, 3, 4, 5], sub ($x) { $x * $x }),
    sub ($x) { $x > 10 ? "big($x)" : "small($x)" },
);
say "fmap chain:  @$result";

# ── Type Classes in Practice ──────────────────────────────
#
# Combine Show with generic functions for display utilities.

sub show_pair :sig(<T, U>(T, U) -> Str) ($a, $b) {
    "(" . Show::show($a) . ", " . Show::show($b) . ")";
}

say "show_pair(1, 'hi'):  ", show_pair(1, "hi");

sub show_list ($arr) {
    "[" . join(", ", map { Show::show($_) } @$arr) . "]";
}

say "show_list([1,2,3]): ", show_list([1, 2, 3]);
