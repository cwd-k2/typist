#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  09 — Type DSL
#
#  Typist::DSL provides constants and constructors for
#  building type expressions programmatically.  Types
#  support operator overloading: | for union, & for
#  intersection, and "" for stringification.
# ═══════════════════════════════════════════════════════════

# ── Atom Constants ────────────────────────────────────────
#
# Imported: Int, Str, Num, Bool, Any, Void, Never, Undef

say "Int:   ", Int;
say "Str:   ", Str;
say "Num:   ", Num;
say "Bool:  ", Bool;
say "Any:   ", Any;
say "Undef: ", Undef;
say "";

# ── Operator Overloading ──────────────────────────────────
#
# | creates Union, & creates Intersection

my $union = Int | Str;
say "Int | Str:     $union";

my $nullable = Int | Undef;
say "Int | Undef:   $nullable";

my $multi = Int | Str | Bool;
say "Int|Str|Bool:  $multi";

say "";

# ── Parametric Constructors ───────────────────────────────

say "ArrayRef[Int]:       ", ArrayRef(Int);
say "HashRef[Str, Int]:   ", HashRef(Str, Int);
say "Maybe[Str]:          ", Maybe(Str);
say "Tuple[Int, Str]:     ", Tuple(Int, Str);
say "Ref[Int]:            ", Ref(Int);
say "";

# ── Struct Constructor ────────────────────────────────────

my $point_t = Record(x => Int, y => Int);
say "Record(x=>Int, y=>Int):  $point_t";

my $config_t = Record(host => Str, port => Int, 'debug?' => Bool);
say "Config with optional:    $config_t";
say "";

# ── Func Constructor ─────────────────────────────────────

my $add_t = Func(Int, Int, returns => Int);
say "Func(Int,Int)->Int:  $add_t";
say "";

# ── Literal Constructor ──────────────────────────────────

my $lit_42 = Literal(42);
say "Literal(42):  $lit_42";

my $lit_ok = Literal("ok");
say 'Literal("ok"):  ', $lit_ok;

# Union of literals
my $status_t = Literal("ok") | Literal("error");
say "status type:  $status_t";
say "";

# ── Type Variables ────────────────────────────────────────
#
# Pre-defined: T, U, V, A, B, K
# Custom: TVar('name')

say "T:   ", T;
say "U:   ", U;
say "";

say "ArrayRef[T]:  ", ArrayRef(T);
say "Func(T)->U:   ", Func(T, returns => U);
say "";

# ── Alias ─────────────────────────────────────────────────
#
# Named reference to a registered type. Resolves lazily.

BEGIN { typedef Email => Str; }

my $alias = Alias('Email');
say "Alias('Email'):  $alias";
say "";

# ── Type Coercion ─────────────────────────────────────────
#
# Type->coerce($expr) accepts both Type objects and strings.

use Typist::Type;

my $t1 = Typist::Type->coerce(Int);         # Type object
my $t2 = Typist::Type->coerce('Str');       # string parsed
my $t3 = Typist::Type->coerce('Int | Str'); # union from string

say "coerce(Int):         $t1";
say "coerce('Str'):       $t2";
say "coerce('Int | Str'): $t3";
say "";

# ── typedef with DSL Expressions ─────────────────────────
#
# typedef uses coerce internally, so DSL expressions work.

BEGIN {
    typedef Name   => Str;
    typedef Age    => Int;
    typedef Person => Record(name => Str, age => Int, 'email?' => Str);
    typedef IdOrName => Str | Int;
}

say "Registered aliases accessible via :sig()";

my $p :sig(Person) = +{ name => "Alice", age => 30 };
say "person: $p->{name}";

my $id :sig(IdOrName) = 42;
$id = "Alice";
say "id: $id";
