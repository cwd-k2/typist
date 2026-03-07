#!/usr/bin/env perl
# Benchmark: Subtype checking — is_subtype + common_super
#
# Covers atom hierarchy, parameterized covariance, union/intersection,
# record width subtyping, function types, and cache effects.
use v5.40;
use lib 'lib';
use Benchmark qw(timethese cmpthese :hireswallclock);

use Typist::Parser;
use Typist::Subtype;

sub T ($expr) { Typist::Parser->parse($expr) }

# Pre-build type objects
my $Int    = T('Int');
my $Num    = T('Num');
my $Str    = T('Str');
my $Any    = T('Any');
my $Bool   = T('Bool');
my $Double = T('Double');

my $ArrInt  = T('ArrayRef[Int]');
my $ArrNum  = T('ArrayRef[Num]');
my $ArrStr  = T('ArrayRef[Str]');
my $ArrAny  = T('ArrayRef[Any]');
my $MaybeInt = T('Maybe[Int]');
my $MaybeNum = T('Maybe[Num]');

my $IntOrStr   = T('Int | Str');
my $IntOrBool  = T('Int | Bool');
my $NumOrStr   = T('Num | Str');

my $RecSmall  = T('{name => Str}');
my $RecMedium = T('{name => Str, age => Int}');
my $RecLarge  = T('{name => Str, age => Int, email => Str, score => Num}');

my $FnAdd     = T('(Int, Int) -> Int');
my $FnAddNum  = T('(Num, Num) -> Num');
my $FnIdStr   = T('(Str) -> Str');

say "=" x 60;
say "  Subtype Benchmark";
say "=" x 60;

# ── Atom hierarchy ────────────────────────────────
say "";
say "  Atom Hierarchy";
say "  " . "-" x 50;

my $r1 = timethese(-2, {
    'fast_path (identity)' => sub {
        Typist::Subtype->clear_cache;
        Typist::Subtype->is_subtype($Int, $Int);
        Typist::Subtype->is_subtype($Str, $Str);
        Typist::Subtype->is_subtype($Any, $Any);
    },
    'fast_path (Any super)' => sub {
        Typist::Subtype->clear_cache;
        Typist::Subtype->is_subtype($Int, $Any);
        Typist::Subtype->is_subtype($Str, $Any);
        Typist::Subtype->is_subtype($Bool, $Any);
    },
    'chain (Bool<:Int<:Num)' => sub {
        Typist::Subtype->clear_cache;
        Typist::Subtype->is_subtype($Bool, $Int);
        Typist::Subtype->is_subtype($Bool, $Num);
        Typist::Subtype->is_subtype($Int, $Num);
    },
    'negative (Str vs Int)' => sub {
        Typist::Subtype->clear_cache;
        Typist::Subtype->is_subtype($Str, $Int);
        Typist::Subtype->is_subtype($Int, $Str);
    },
});
cmpthese($r1);

# ── Parameterized + Union ────────────────────────
say "";
say "  Parameterized & Union";
say "  " . "-" x 50;

my $r2 = timethese(-2, {
    'param covariant' => sub {
        Typist::Subtype->clear_cache;
        Typist::Subtype->is_subtype($ArrInt, $ArrNum);
        Typist::Subtype->is_subtype($ArrInt, $ArrAny);
    },
    'maybe (union+param)' => sub {
        Typist::Subtype->clear_cache;
        Typist::Subtype->is_subtype($MaybeInt, $MaybeNum);
    },
    'union subtype' => sub {
        Typist::Subtype->clear_cache;
        Typist::Subtype->is_subtype($IntOrBool, $NumOrStr);
        Typist::Subtype->is_subtype($Int, $IntOrStr);
    },
});
cmpthese($r2);

# ── Record + Function ────────────────────────────
say "";
say "  Record & Function";
say "  " . "-" x 50;

my $r3 = timethese(-2, {
    'record width' => sub {
        Typist::Subtype->clear_cache;
        Typist::Subtype->is_subtype($RecLarge, $RecSmall);
        Typist::Subtype->is_subtype($RecMedium, $RecSmall);
    },
    'function types' => sub {
        Typist::Subtype->clear_cache;
        Typist::Subtype->is_subtype($FnAdd, $FnAddNum);
    },
});
cmpthese($r3);

# ── Cache effect ─────────────────────────────────
say "";
say "  Cache Effect (cold vs hot)";
say "  " . "-" x 50;

my $r4 = timethese(-2, {
    'cold (clear each)' => sub {
        Typist::Subtype->clear_cache;
        Typist::Subtype->is_subtype($ArrInt, $ArrNum);
        Typist::Subtype->is_subtype($RecLarge, $RecSmall);
        Typist::Subtype->is_subtype($FnAdd, $FnAddNum);
    },
    'hot (cached)' => sub {
        Typist::Subtype->is_subtype($ArrInt, $ArrNum);
        Typist::Subtype->is_subtype($RecLarge, $RecSmall);
        Typist::Subtype->is_subtype($FnAdd, $FnAddNum);
    },
});
cmpthese($r4);

# ── common_super ─────────────────────────────────
say "";
say "  LUB (common_super)";
say "  " . "-" x 50;

my $r5 = timethese(-2, {
    'atom LUB' => sub {
        Typist::Subtype->common_super($Bool, $Int);
        Typist::Subtype->common_super($Int, $Double);
        Typist::Subtype->common_super($Int, $Str);
    },
    'param LUB' => sub {
        Typist::Subtype->common_super($ArrInt, $ArrNum);
        Typist::Subtype->common_super($ArrInt, $ArrStr);
    },
    'record LUB' => sub {
        Typist::Subtype->common_super($RecSmall, $RecMedium);
        Typist::Subtype->common_super($RecMedium, $RecLarge);
    },
});
cmpthese($r5);
say "";
