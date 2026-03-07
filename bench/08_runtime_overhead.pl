#!/usr/bin/env perl
# Benchmark: Runtime overhead — Typist constructs vs plain Perl
#
# Measures the cost Typist adds on top of equivalent plain Perl operations.
# This is the "tax" users pay for type safety at runtime.
#
# Sections:
#   1. Function call: :sig() wrapped vs bare sub
#   2. Variable assignment: Tie::Scalar vs plain scalar
#   3. Struct vs plain hashref (construction + access)
#   4. Newtype vs plain scalar
use v5.40;
use lib 'lib';

$ENV{TYPIST_CHECK_QUIET} = 1;

# Suppress "attribute may clash" warning from :sig on lexicals outside subs
no warnings 'misc';
use Typist -runtime;
use Benchmark qw(timethese cmpthese :hireswallclock);

# ═══════════════════════════════════════════════════════════
#  Setup: define typed and untyped counterparts
# ═══════════════════════════════════════════════════════════

BEGIN {
    struct 'Point' => (x => 'Num', y => 'Num');
    struct 'User'  => (name => 'Str', age => 'Int', email => 'Str');
    newtype 'UserId' => 'Int';
}

# ── Typed functions (runtime-wrapped via :sig) ────
sub add_typed :sig((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

sub identity_typed :sig(<T>(T) -> T) ($x) {
    $x;
}

sub concat_typed :sig((Str, Str) -> Str) ($a, $b) {
    $a . $b;
}

# ── Bare equivalents (no Typist involvement) ─────
sub add_bare ($a, $b) {
    $a + $b;
}

sub identity_bare ($x) {
    $x;
}

sub concat_bare ($a, $b) {
    $a . $b;
}

say "=" x 60;
say "  Runtime Overhead Benchmark";
say "=" x 60;

# ── 1. Function Call ─────────────────────────────
say "";
say "  1. Function Call (:sig wrapped vs bare)";
say "  " . "-" x 50;

my $r1 = timethese(-2, {
    'add bare' => sub {
        add_bare(1, 2);
    },
    'add :sig(Int,Int)->Int' => sub {
        add_typed(1, 2);
    },
    'concat bare' => sub {
        concat_bare("hello", "world");
    },
    'concat :sig(Str,Str)->Str' => sub {
        concat_typed("hello", "world");
    },
    'identity bare' => sub {
        identity_bare(42);
    },
    'identity :sig(<T>(T)->T)' => sub {
        identity_typed(42);
    },
});
cmpthese($r1);

# ── 2. Variable Assignment ───────────────────────
say "";
say "  2. Variable Assignment (Tie::Scalar vs plain)";
say "  " . "-" x 50;

my $plain = 0;
my $typed :sig(Int) = 0;

# Batch 100 ops per iteration to reduce Benchmark loop overhead
# and make plain/typed measurements comparable.
my $r2 = timethese(-2, {
    'plain write x100' => sub {
        $plain = $_ for 1 .. 100;
    },
    'typed write x100' => sub {
        $typed = $_ for 1 .. 100;
    },
    'plain read x100' => sub {
        my $v;
        $v = $plain for 1 .. 100;
    },
    'typed read x100' => sub {
        my $v;
        $v = $typed for 1 .. 100;
    },
});
cmpthese($r2);

# ── 3. Struct vs Hashref ─────────────────────────
say "";
say "  3. Struct vs Plain Hashref";
say "  " . "-" x 50;

my $pt_struct  = Point(x => 1.0, y => 2.0);
my $pt_hash    = +{ x => 1.0, y => 2.0 };

my $usr_struct = User(name => "Alice", age => 30, email => 'a@b.com');
my $usr_hash   = +{ name => "Alice", age => 30, email => 'a@b.com' };

my $r3 = timethese(-2, {
    'hashref {x,y}' => sub {
        +{ x => 1.0, y => 2.0 };
    },
    'Point(x,y)' => sub {
        Point(x => 1.0, y => 2.0);
    },
    'hashref {3 fields}' => sub {
        +{ name => "Alice", age => 30, email => 'a@b.com' };
    },
    'User(3 fields)' => sub {
        User(name => "Alice", age => 30, email => 'a@b.com');
    },
});
cmpthese($r3);

say "";
say "  3b. Struct Access vs Hashref Access";
say "  " . "-" x 50;

my $r3b = timethese(-2, {
    'hashref->{x}' => sub {
        $pt_hash->{x};
    },
    'Point->x' => sub {
        $pt_struct->x;
    },
    'hashref->{name}' => sub {
        $usr_hash->{name};
    },
    'User->name' => sub {
        $usr_struct->name;
    },
});
cmpthese($r3b);

# ── 4. Newtype vs Plain Scalar ───────────────────
say "";
say "  4. Newtype vs Plain Scalar";
say "  " . "-" x 50;

my $r4 = timethese(-2, {
    'plain assign' => sub {
        my $id = 42;
    },
    'UserId(42)' => sub {
        my $id = UserId(42);
    },
    'plain read' => sub {
        my $id = 42;
        my $v  = $id;
    },
    'UserId + coerce' => sub {
        my $id = UserId(42);
        my $v  = UserId::coerce($id);
    },
});
cmpthese($r4);
say "";
