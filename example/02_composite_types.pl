#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  02 — Composite Types
#
#  Building complex types from primitives: Struct, Union,
#  Maybe, ArrayRef, HashRef, Tuple, optional fields, and
#  nesting.
# ═══════════════════════════════════════════════════════════

# ── Struct ────────────────────────────────────────────────
#
# Struct(k => T, ...) defines a record type.
# Values are plain hashrefs — Typist checks field presence and types.

BEGIN {
    typedef Point  => Struct(x => Int, y => Int);
    typedef Person => Struct(name => Str, age => Int);
}

my $origin :Type(Point) = +{ x => 0, y => 0 };
say "origin: ($origin->{x}, $origin->{y})";

my $alice :Type(Person) = +{ name => "Alice", age => 30 };
say "person: $alice->{name}, age $alice->{age}";

# Missing required field
eval { my $bad :Type(Person) = +{ name => "Bob" } };
say "Person w/o age:   $@" if $@;

# Wrong field type
eval { my $bad :Type(Person) = +{ name => "Carol", age => "young" } };
say "Person age=Str:   $@" if $@;

# ── Optional Struct Fields ────────────────────────────────
#
# Append ? to the key name. Omitted fields are OK;
# present fields must match the declared type.

BEGIN {
    typedef Config => Struct(
        host      => Str,
        port      => Int,
        'debug?'  => Bool,
        'label?'  => Str,
    );
}

my $cfg :Type(Config) = +{ host => "localhost", port => 8080 };
say "config: $cfg->{host}:$cfg->{port}";

$cfg = +{ host => "0.0.0.0", port => 443, debug => 1 };
say "config with debug: $cfg->{host}:$cfg->{port} debug=$cfg->{debug}";

# Optional field present but wrong type
eval { $cfg = +{ host => "h", port => 80, debug => "yes" } };
say "Config debug=Str:  $@" if $@;

# ── Union Types ───────────────────────────────────────────
#
# T | U accepts values matching either type.

my $id :Type(Int | Str) = 42;
say "id (Int): $id";

$id = "ABC-123";
say "id (Str): $id";

eval { $id = [1, 2] };
say "Int|Str <- ArrayRef:  $@" if $@;

# Union of more types
BEGIN { typedef Status => Str; }

my $result :Type(Int | Str | Undef) = undef;
$result = 200;
$result = "OK";
say "result: $result";

# ── Maybe[T] ─────────────────────────────────────────────
#
# Maybe[T] desugars to T | Undef.

my $score :Type(Maybe[Int]) = undef;
$score = 95;
say "score: ", $score // "(none)";

$score = undef;
say "score: ", $score // "(none)";

eval { $score = "high" };
say "Maybe[Int] <- Str:  $@" if $@;

# ── ArrayRef[T] ──────────────────────────────────────────
#
# Homogeneous arrays. Every element must match T.

my $nums :Type(ArrayRef[Int]) = [1, 2, 3];
say "nums: @$nums";

eval { $nums = [1, "two", 3] };
say "ArrayRef[Int] <- mixed:  $@" if $@;

eval { $nums = "not an array" };
say "ArrayRef[Int] <- Str:    $@" if $@;

# ── HashRef[K, V] ────────────────────────────────────────
#
# Two-parameter form: key type K, value type V.

my $ages :Type(HashRef[Str, Int]) = +{ alice => 30, bob => 25 };
say "ages: alice=$ages->{alice}";

eval { $ages = +{ alice => "thirty" } };
say "HashRef[Str,Int] value=Str:  $@" if $@;

# ── Tuple[T1, T2, ...] ───────────────────────────────────
#
# Fixed-length array with per-position types.

my $pair :Type(Tuple[Str, Int]) = ["Alice", 30];
say "tuple: ($pair->[0], $pair->[1])";

eval { my $bad :Type(Tuple[Str, Int]) = ["Alice", "thirty"] };
say "Tuple[Str,Int] <- [Str,Str]:  $@" if $@;

# ── Ref[T] ────────────────────────────────────────────────
#
# Scalar reference to a value of type T.

my $ref :Type(Ref[Int]) = \42;
say "ref: $$ref";

eval { my $bad :Type(Ref[Int]) = \"hello" };
say "Ref[Int] <- \\Str:  $@" if $@;

# ── Nesting ───────────────────────────────────────────────
#
# Types compose freely: ArrayRef of Struct, HashRef of arrays, etc.

BEGIN {
    typedef UserList => ArrayRef(Struct(name => Str, age => Int));
    typedef Matrix   => ArrayRef(ArrayRef(Int));
}

my $users :Type(UserList) = [
    +{ name => "Alice", age => 30 },
    +{ name => "Bob",   age => 25 },
];
say "users: ", scalar @$users, " entries";

# One invalid element fails the whole array
eval {
    $users = [
        +{ name => "Carol", age => 28 },
        +{ name => "Dave" },
    ];
};
say "UserList missing age:  $@" if $@;

my $mat :Type(Matrix) = [[1, 2], [3, 4]];
say "matrix[0][1] = $mat->[0][1]";
