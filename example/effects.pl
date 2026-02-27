#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist;

# ── Effect Definitions ──────────────────────────

BEGIN {
    effect Console => +{
        readLine  => 'CodeRef[-> Str]',
        writeLine => 'CodeRef[Str -> Void]',
    };

    effect Log => +{
        log => 'CodeRef[Str -> Void]',
    };
}

# ── Single Effect ───────────────────────────────

sub greet :Params(Str) :Returns(Str) :Eff(Console) ($name) {
    "Hello, $name!";
}

say greet("Alice");

# ── Multiple Effects ────────────────────────────

sub greet_logged :Params(Str) :Returns(Str) :Eff(Console | Log) ($name) {
    "Hello, $name! (logged)";
}

say greet_logged("Bob");

# ── Row Polymorphism ────────────────────────────

# :Generic(r: Row) declares r as a row variable.
# :Eff(Log | r) means "at least Log, plus whatever r adds."
# Callers can supply any additional effects through r.

sub with_log :Generic(r: Row) :Params(Str) :Returns(Str) :Eff(Log | r) ($msg) {
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

# :Eff is phantom — it annotates but does not alter runtime behavior.
# Static analysis catches effect mismatches; runtime runs freely.

sub pure_add :Params(Int, Int) :Returns(Int) ($a, $b) {
    $a + $b;
}

say "2 + 3 = ", pure_add(2, 3);

eval { greet([1, 2]) };
say "Caught: $@" if $@;
