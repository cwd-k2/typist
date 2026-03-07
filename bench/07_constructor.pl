#!/usr/bin/env perl
# Benchmark: Constructor — struct/newtype creation
#
# Measures struct construction cost (structural checks always-on)
# and newtype wrapping.  Runtime type validation is tested separately.
#
# Structs use function-call syntax: Point(x => 1, y => 2)
# Newtypes use function-call syntax: UserId(42)
use v5.40;
use lib 'lib';

# Suppress CHECK-phase output
$ENV{TYPIST_CHECK_QUIET} = 1;

use Typist;
use Benchmark qw(timethese cmpthese :hireswallclock);

BEGIN {
    struct 'Point' => (
        x => 'Num',
        y => 'Num',
    );

    struct 'User' => (
        name  => 'Str',
        age   => 'Int',
        email => 'Str',
    );

    struct 'BigStruct' => (
        f1  => 'Str', f2  => 'Int', f3  => 'Num',
        f4  => 'Str', f5  => 'Int', f6  => 'Num',
        f7  => 'Str', f8  => 'Int', f9  => 'Num',
        f10 => 'Str',
    );

    newtype 'UserId'   => 'Int';
    newtype 'Email'    => 'Str';
    newtype 'Price'    => 'Num';
}

say "=" x 60;
say "  Constructor Benchmark";
say "=" x 60;

# ── Struct construction ──────────────────────────
say "";
say "  Struct Construction (static-only — structural checks)";
say "  " . "-" x 50;

my $r1 = timethese(-2, {
    'Point (2 fields)' => sub {
        Point(x => 1.0, y => 2.0);
    },
    'User (3 fields)' => sub {
        User(name => "Alice", age => 30, email => 'a@b.com');
    },
    'BigStruct (10 fields)' => sub {
        BigStruct(
            f1 => "a", f2 => 1, f3 => 1.0,
            f4 => "b", f5 => 2, f6 => 2.0,
            f7 => "c", f8 => 3, f9 => 3.0,
            f10 => "d",
        );
    },
});
cmpthese($r1);

# ── Struct accessors ─────────────────────────────
say "";
say "  Struct Accessors";
say "  " . "-" x 50;

my $pt   = Point(x => 1.0, y => 2.0);
my $user = User(name => "Alice", age => 30, email => 'a@b.com');
my $big  = BigStruct(
    f1 => "a", f2 => 1, f3 => 1.0,
    f4 => "b", f5 => 2, f6 => 2.0,
    f7 => "c", f8 => 3, f9 => 3.0,
    f10 => "d",
);

my $r2 = timethese(-2, {
    'Point->x' => sub { $pt->x },
    'User->name' => sub { $user->name },
    'BigStruct->f10' => sub { $big->f10 },
});
cmpthese($r2);

# ── Struct derive (immutable copy) ───────────────
say "";
say "  Struct derive (immutable update)";
say "  " . "-" x 50;

my $r3 = timethese(-2, {
    'Point derive' => sub {
        Point::derive($pt, x => 5.0);
    },
    'User derive' => sub {
        User::derive($user, age => 31);
    },
});
cmpthese($r3);

# ── Newtype wrap/coerce ──────────────────────────
say "";
say "  Newtype (wrap + coerce)";
say "  " . "-" x 50;

my $r4 = timethese(-2, {
    'UserId wrap' => sub {
        UserId(42);
    },
    'Email wrap' => sub {
        Email('test@example.com');
    },
    'UserId coerce' => sub {
        my $id = UserId(42);
        UserId::coerce($id);
    },
});
cmpthese($r4);
say "";
