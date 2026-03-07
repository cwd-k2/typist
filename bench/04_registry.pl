#!/usr/bin/env perl
# Benchmark: Registry operations
#
# Registration, lookup, and search at various scales.
use v5.40;
use lib 'lib';
use Benchmark qw(timethese cmpthese :hireswallclock);

use Typist::Registry;
use Typist::Parser;
use Typist::Prelude;

sub T ($expr) { Typist::Parser->parse($expr) }

say "=" x 60;
say "  Registry Benchmark";
say "=" x 60;

# ── Registration ──────────────────────────────────
say "";
say "  Registration";
say "  " . "-" x 50;

my $r1 = timethese(-2, {
    'new + prelude' => sub {
        my $reg = Typist::Registry->new;
        Typist::Prelude->install($reg);
    },
    'define_alias' => sub {
        my $reg = Typist::Registry->new;
        $reg->define_alias("Type_$_", 'Int') for 1 .. 50;
    },
    'register_function' => sub {
        my $reg = Typist::Registry->new;
        $reg->register_function('main', "fn_$_", T('(Int) -> Int')) for 1 .. 50;
    },
});
cmpthese($r1);

# ── Lookup ────────────────────────────────────────
say "";
say "  Lookup (prelude-populated registry)";
say "  " . "-" x 50;

my $reg = Typist::Registry->new;
Typist::Prelude->install($reg);
# Add some aliases and functions
$reg->define_alias("UserName", 'Str');
$reg->define_alias("Age", 'Int');
$reg->define_alias("Score", 'Num');
$reg->register_function('main', "get_name", T('() -> Str'));
$reg->register_function('main', "add", T('(Int, Int) -> Int'));
$reg->register_function('main', "process", T('(Str, ArrayRef[Int]) -> Bool'));

my $r2 = timethese(-2, {
    'lookup_type (hit)' => sub {
        $reg->lookup_type('UserName');
        $reg->lookup_type('Age');
    },
    'lookup_type (miss)' => sub {
        $reg->lookup_type('Nonexistent');
    },
    'lookup_function' => sub {
        $reg->lookup_function('main', 'add');
        $reg->lookup_function('main', 'process');
    },
    'search_function_by_name' => sub {
        $reg->search_function_by_name('add');
        $reg->search_function_by_name('process');
    },
});
cmpthese($r2);

# ── Scaled lookup ────────────────────────────────
say "";
say "  Scaled Lookup (N aliases)";
say "  " . "-" x 50;

for my $n (100, 500, 1000) {
    my $r = Typist::Registry->new;
    Typist::Prelude->install($r);
    $r->define_alias("Type_$_", "ArrayRef[Int]") for 1 .. $n;

    my $res = timethese(-1, {
        "lookup_first (n=$n)" => sub { $r->lookup_type('Type_1') },
        "lookup_last (n=$n)"  => sub { $r->lookup_type("Type_$n") },
        "lookup_miss (n=$n)"  => sub { $r->lookup_type('Missing') },
    });
    cmpthese($res);
}
say "";
