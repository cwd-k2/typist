#!/usr/bin/env perl
# Benchmark: Type object operations
#
# Measures equals, to_string, free_vars, contains, substitute, and Type::Fold.
use v5.40;
use lib 'lib';
use Benchmark qw(timethese cmpthese :hireswallclock);

use Typist::Parser;
use Typist::Type::Fold;

sub T ($expr)  { Typist::Parser->parse($expr) }
sub TA ($expr) { Typist::Parser->parse_annotation($expr)->{type} }

my $Int    = T('Int');
my $ArrInt = T('ArrayRef[Int]');
my $Func   = T('(Int, Str) -> Bool');
my $Union  = T('Int | Str | Bool');
my $Record = T('{name => Str, age => Int, email? => Str}');
my $Deep   = T('ArrayRef[HashRef[Str, ArrayRef[Maybe[Int]]]]');
my $GenFn  = TA('<T, U>(T, ArrayRef[U]) -> HashRef[T, U]');
my $Eff    = TA('(Int) -> Str ![Console]');

say "=" x 60;
say "  Type Operations Benchmark";
say "=" x 60;

# ── equals ────────────────────────────────────────
say "";
say "  equals";
say "  " . "-" x 50;

# Build identical copies for non-trivial equals
my $ArrInt2 = T('ArrayRef[Int]');
my $Record2 = T('{name => Str, age => Int, email? => Str}');
my $Deep2   = T('ArrayRef[HashRef[Str, ArrayRef[Maybe[Int]]]]');

my $r1 = timethese(-2, {
    'atom identity' => sub {
        $Int->equals($Int);
    },
    'param structural' => sub {
        $ArrInt->equals($ArrInt2);
    },
    'record structural' => sub {
        $Record->equals($Record2);
    },
    'deep structural' => sub {
        $Deep->equals($Deep2);
    },
});
cmpthese($r1);

# ── to_string ─────────────────────────────────────
say "";
say "  to_string";
say "  " . "-" x 50;

my $r2 = timethese(-2, {
    'atom' => sub { $Int->to_string },
    'parameterized' => sub { $ArrInt->to_string },
    'function' => sub { $Func->to_string },
    'union' => sub { $Union->to_string },
    'record' => sub { $Record->to_string },
    'deep' => sub { $Deep->to_string },
});
cmpthese($r2);

# ── free_vars ─────────────────────────────────────
say "";
say "  free_vars";
say "  " . "-" x 50;

my $HasVars  = TA('<T>(T, ArrayRef[T]) -> T');
my $NoVars   = T('(Int, Str) -> Bool');
my $ManyVars = TA('<T, U, V>(T, HashRef[U, V]) -> Tuple[T, U]');

my $r3 = timethese(-2, {
    'no free vars' => sub { $NoVars->free_vars },
    'generic body' => sub {
        # The body of a generic func — has free T
        $HasVars->free_vars;
    },
    'complex' => sub { $ManyVars->free_vars },
});
cmpthese($r3);

# ── Type::Fold ────────────────────────────────────
say "";
say "  Type::Fold (map_type / walk)";
say "  " . "-" x 50;

my $identity_map = sub { $_[0] };
my $r4 = timethese(-2, {
    'walk atom' => sub {
        my $n = 0;
        Typist::Type::Fold->walk($Int, sub { $n++ });
    },
    'walk deep' => sub {
        my $n = 0;
        Typist::Type::Fold->walk($Deep, sub { $n++ });
    },
    'walk generic_fn' => sub {
        my $n = 0;
        Typist::Type::Fold->walk($GenFn, sub { $n++ });
    },
    'map_type identity' => sub {
        Typist::Type::Fold->map_type($Deep, $identity_map);
    },
});
cmpthese($r4);
say "";
