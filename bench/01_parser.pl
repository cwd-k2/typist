#!/usr/bin/env perl
# Benchmark: Parser — tokenize + parse type expressions
#
# Tests cache-cold (first parse) and cache-hot (repeated parse) paths.
# Parser is a critical hot path for both static analysis and runtime.
#
# parse()            — type expressions:  'Int', 'ArrayRef[Int]', '(Int) -> Str'
# parse_annotation() — :sig() content:    '<T>(T) -> T', '<T: Num>(T, T) -> T'
use v5.40;
use lib 'lib';
use Benchmark qw(timethese cmpthese :hireswallclock);

use Typist::Parser;

# Type expressions (for parse)
my @type_exprs = (
    'Int', 'Str', 'Bool',
    'ArrayRef[Int]', 'HashRef[Str, Int]', 'Maybe[Str]',
    'ArrayRef[Maybe[Int]]', 'HashRef[Str, ArrayRef[Int]]',
    '(Int, Int) -> Int', '(Str) -> Bool', '(ArrayRef[Int]) -> Int',
    'Int | Str | Bool', 'Int & Comparable',
    '{name => Str, age => Int}', '{name => Str, age => Int, email? => Str}',
    'ArrayRef[HashRef[Str, ArrayRef[Maybe[Int]]]]',
);

# Annotation expressions (for parse_annotation)
my @annotations = (
    '(Int, Int) -> Int',
    '(Str) -> Str',
    '<T>(T) -> T',
    '<T>(ArrayRef[T]) -> T',
    '<T, U>(T, U) -> Tuple[T, U]',
    '<T: Num>(T, T) -> T',
    '<T: Num>(ArrayRef[T], (T, T) -> T) -> T ![Console]',
);

say "=" x 60;
say "  Parser Benchmark";
say "=" x 60;

# ── Cold parse (clear cache each time) ─────────────
say "";
say "  Cold Parse — parse() (cache miss)";
say "  " . "-" x 50;

my $results_cold = timethese(-2, {
    'simple_atoms' => sub {
        Typist::Parser->_clear_cache;
        Typist::Parser->parse('Int');
        Typist::Parser->parse('Str');
        Typist::Parser->parse('Bool');
    },
    'parameterized' => sub {
        Typist::Parser->_clear_cache;
        Typist::Parser->parse('ArrayRef[Int]');
        Typist::Parser->parse('HashRef[Str, Int]');
        Typist::Parser->parse('Maybe[Str]');
    },
    'function_types' => sub {
        Typist::Parser->_clear_cache;
        Typist::Parser->parse('(Int, Int) -> Int');
        Typist::Parser->parse('(Str) -> Bool');
    },
    'deep_nesting' => sub {
        Typist::Parser->_clear_cache;
        Typist::Parser->parse('ArrayRef[HashRef[Str, ArrayRef[Maybe[Int]]]]');
    },
});
cmpthese($results_cold);

# ── Cold parse_annotation ────────────────────────
say "";
say "  Cold Parse — parse_annotation() (cache miss)";
say "  " . "-" x 50;

my $results_ann = timethese(-2, {
    'simple_fn' => sub {
        Typist::Parser->_clear_cache;
        Typist::Parser->parse_annotation('(Int, Int) -> Int');
    },
    'generic' => sub {
        Typist::Parser->_clear_cache;
        Typist::Parser->parse_annotation('<T>(T) -> T');
    },
    'bounded+effects' => sub {
        Typist::Parser->_clear_cache;
        Typist::Parser->parse_annotation('<T: Num>(ArrayRef[T], (T, T) -> T) -> T ![Console]');
    },
});
cmpthese($results_ann);

# ── Hot parse (cache hit) ─────────────────────────
say "";
say "  Hot Parse (cache hit — repeated)";
say "  " . "-" x 50;

# Prime caches
Typist::Parser->_clear_cache;
Typist::Parser->parse($_) for @type_exprs;
Typist::Parser->parse_annotation($_) for @annotations;

my $results_hot = timethese(-2, {
    'parse hit (simple)' => sub {
        Typist::Parser->parse('Int');
        Typist::Parser->parse('Str');
        Typist::Parser->parse('Bool');
    },
    'parse hit (deep)' => sub {
        Typist::Parser->parse('ArrayRef[HashRef[Str, ArrayRef[Maybe[Int]]]]');
    },
    'annotation hit (generic)' => sub {
        Typist::Parser->parse_annotation('<T>(T) -> T');
    },
    'annotation hit (complex)' => sub {
        Typist::Parser->parse_annotation('<T: Num>(ArrayRef[T], (T, T) -> T) -> T ![Console]');
    },
    'all types (16 exprs)' => sub {
        Typist::Parser->parse($_) for @type_exprs;
    },
});
cmpthese($results_hot);
say "";
