#!/usr/bin/env perl
# Benchmark: Static analysis pipeline — end-to-end Analyzer
#
# Measures the full Extractor → Registration → Checker → TypeEnv →
# TypeChecker → EffectChecker pipeline on realistic Typist source code.
use v5.40;
use lib 'lib';
use Benchmark qw(timethese cmpthese :hireswallclock);

# Suppress CHECK-phase output
$ENV{TYPIST_CHECK_QUIET} = 1;

use Typist::Static::Analyzer;
use Typist::Static::Extractor;

say "=" x 60;
say "  Static Analyzer Benchmark";
say "=" x 60;

# ── Test sources ──────────────────────────────────

my $source_minimal = <<'PERL';
use v5.40;
use Typist;

sub greet :sig((Str) -> Str) ($who) {
    "Hello, $who!";
}
PERL

my $source_medium = <<'PERL';
use v5.40;
use Typist;

BEGIN {
    typedef Name => 'Str';
    typedef Age  => 'Int';
}

sub greet :sig((Name) -> Str) ($name) {
    "Hello, $name!";
}

sub add :sig((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

sub identity :sig(<T>(T) -> T) ($x) {
    $x;
}

sub first :sig(<T>(ArrayRef[T]) -> T) ($arr) {
    $arr->[0];
}

sub clamp :sig((Int, Int, Int) -> Int) ($val, $lo, $hi) {
    $val < $lo ? $lo : $val > $hi ? $hi : $val;
}

my $score :sig(Int) = 100;
my $name  :sig(Name) = "Alice";
PERL

my $source_complex = <<'PERL';
use v5.40;
use Typist;

BEGIN {
    typedef UserId  => 'Int';
    typedef Email   => 'Str';
    typedef Price   => 'Num';
    typedef Json    => 'HashRef[Str, Any]';

    struct 'User' => (
        id    => 'UserId',
        name  => 'Str',
        email => 'Email',
    );

    struct 'Product' => (
        id    => 'Int',
        name  => 'Str',
        price => 'Price',
    );
}

effect Logger => +{
    log => '(Str) -> Void',
};

sub find_user :sig((UserId) -> Maybe[User]) ($id) {
    undef;
}

sub format_price :sig((Price) -> Str) ($p) {
    sprintf("$%.2f", $p);
}

sub process_order :sig((User, ArrayRef[Product]) -> Str ![Logger]) ($user, $items) {
    Logger::log("Processing order for " . $user->name);
    my $total = 0;
    for my $item (@$items) {
        $total += $item->price;
    }
    format_price($total);
}

sub identity :sig(<T>(T) -> T) ($x) { $x }
sub first :sig(<T>(ArrayRef[T]) -> T) ($arr) { $arr->[0] }
sub map_arr :sig(<T, U>(ArrayRef[T], (T) -> U) -> ArrayRef[U]) ($arr, $f) {
    [map { $f->($_) } @$arr];
}
PERL

# ── Extractor only ───────────────────────────────
say "";
say "  Extractor (PPI parse + extraction)";
say "  " . "-" x 50;

my $r1 = timethese(-2, {
    'minimal (1 fn)' => sub {
        Typist::Static::Extractor->extract($source_minimal);
    },
    'medium (5 fn + vars)' => sub {
        Typist::Static::Extractor->extract($source_medium);
    },
    'complex (effects+structs+generics)' => sub {
        Typist::Static::Extractor->extract($source_complex);
    },
});
cmpthese($r1);

# ── Full pipeline ────────────────────────────────
say "";
say "  Full Analyzer Pipeline";
say "  " . "-" x 50;

my $r2 = timethese(-2, {
    'minimal' => sub {
        Typist::Static::Analyzer->analyze($source_minimal);
    },
    'medium' => sub {
        Typist::Static::Analyzer->analyze($source_medium);
    },
    'complex' => sub {
        Typist::Static::Analyzer->analyze($source_complex);
    },
});
cmpthese($r2);

# ── Pre-extracted (skip PPI) ─────────────────────
say "";
say "  Analyzer (pre-extracted, skip PPI parse)";
say "  " . "-" x 50;

my $ext_minimal = Typist::Static::Extractor->extract($source_minimal);
my $ext_medium  = Typist::Static::Extractor->extract($source_medium);
my $ext_complex = Typist::Static::Extractor->extract($source_complex);

my $r3 = timethese(-2, {
    'minimal (no PPI)' => sub {
        Typist::Static::Analyzer->analyze($source_minimal, extracted => $ext_minimal);
    },
    'medium (no PPI)' => sub {
        Typist::Static::Analyzer->analyze($source_medium, extracted => $ext_medium);
    },
    'complex (no PPI)' => sub {
        Typist::Static::Analyzer->analyze($source_complex, extracted => $ext_complex);
    },
});
cmpthese($r3);
say "";
