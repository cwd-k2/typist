#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL;

# ── Effect Definitions ──────────────────────────

BEGIN {
    effect Console => +{
        readLine  => Func(returns => Str),
        writeLine => Func(Str, returns => Void),
    };

    effect Log => +{
        log => Func(Str, returns => Void),
    };
}

# ── Single Effect ───────────────────────────────

sub greet :Type((Str) -> Str ! Console) ($name) {
    "Hello, $name!";
}

say greet("Alice");

# ── Multiple Effects ────────────────────────────

sub greet_logged :Type((Str) -> Str ! Console | Log) ($name) {
    "Hello, $name! (logged)";
}

say greet_logged("Bob");

# ── Row Polymorphism ────────────────────────────

# <r: Row> declares r as a row variable.
# ! Log | r means "at least Log, plus whatever r adds."
# Callers can supply any additional effects through r.

sub with_log :Type(<r: Row>(Str) -> Str ! Log | r) ($msg) {
    $msg;
}

say with_log("polymorphic effects");

# ── Effect Rows in the Registry ─────────────────

my $sig = Typist::Registry->lookup_function('main', 'greet');
say "greet       : ", $sig->{effects}->to_string;

$sig = Typist::Registry->lookup_function('main', 'greet_logged');
say "greet_logged: ", $sig->{effects}->to_string;

$sig = Typist::Registry->lookup_function('main', 'with_log');
say "with_log    : ", $sig->{effects}->to_string;

# ── Phantom: Types Enforce, Runtime Flows ───────

# Effects are phantom — they annotate but do not alter runtime behavior.
# Static analysis catches effect mismatches; runtime runs freely.

sub pure_add :Type((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

say "2 + 3 = ", pure_add(2, 3);

eval { greet([1, 2]) };
say "Caught: $@" if $@;
