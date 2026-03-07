#!/usr/bin/env perl
# Benchmark: Runtime inference — Inference::infer_value
#
# Measures type inference from Perl values: scalars, arrays, hashes,
# nested structures. This is the runtime-path cost.
use v5.40;
use lib 'lib';
use Benchmark qw(timethese cmpthese :hireswallclock);

use Typist::Inference;
use Typist::Subtype;

say "=" x 60;
say "  Runtime Inference Benchmark";
say "=" x 60;

# ── Scalar inference ──────────────────────────────
say "";
say "  Scalar Values";
say "  " . "-" x 50;

my $r1 = timethese(-2, {
    'int' => sub {
        Typist::Inference->infer_value(42);
    },
    'double' => sub {
        Typist::Inference->infer_value(3.14);
    },
    'string' => sub {
        Typist::Inference->infer_value("hello");
    },
    'undef' => sub {
        Typist::Inference->infer_value(undef);
    },
    'bool (empty)' => sub {
        Typist::Inference->infer_value('');
    },
});
cmpthese($r1);

# ── Composite inference ──────────────────────────
say "";
say "  Composite Values";
say "  " . "-" x 50;

my @small_arr  = (1, 2, 3);
my @medium_arr = (1 .. 50);
my @large_arr  = (1 .. 500);
my @mixed_arr  = (1, 2.5, "x");

my %small_hash  = (a => 1, b => 2);
my %medium_hash = map { ("k$_" => $_) } 1 .. 50;
my %nested = (
    users => [
        { name => "Alice", age => 30 },
        { name => "Bob",   age => 25 },
    ],
);

my $r2 = timethese(-2, {
    'array (3 elem)' => sub {
        Typist::Inference->infer_value(\@small_arr);
    },
    'array (50 elem)' => sub {
        Typist::Inference->infer_value(\@medium_arr);
    },
    'array (500 elem)' => sub {
        Typist::Inference->infer_value(\@large_arr);
    },
    'array (mixed)' => sub {
        Typist::Inference->infer_value(\@mixed_arr);
    },
    'hash (2 keys)' => sub {
        Typist::Inference->infer_value(\%small_hash);
    },
    'hash (50 keys)' => sub {
        Typist::Inference->infer_value(\%medium_hash);
    },
    'nested structure' => sub {
        Typist::Inference->infer_value(\%nested);
    },
});
cmpthese($r2);

# ── Instantiation (generic unification) ──────────
say "";
say "  Generic Instantiation (unify)";
say "  " . "-" x 50;

use Typist::Parser;
use Typist::Type::Var;
use Typist::Type::Atom;

sub T ($e) { Typist::Parser->parse($e) }

my $sig_identity = {
    params => [Typist::Type::Var->new('T')],
    return => Typist::Type::Var->new('T'),
};

my $sig_pair = {
    params => [Typist::Type::Var->new('T'), Typist::Type::Var->new('U')],
    return => T('Tuple[T, U]'),
};

my @args_int     = (T('Int'));
my @args_int_str = (T('Int'), T('Str'));

my $r3 = timethese(-2, {
    'identity<Int>' => sub {
        Typist::Inference->instantiate($sig_identity, \@args_int);
    },
    'pair<Int,Str>' => sub {
        Typist::Inference->instantiate($sig_pair, \@args_int_str);
    },
});
cmpthese($r3);
say "";
