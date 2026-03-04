#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist;         # static-only: errors appear as warnings, program continues
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  11 — Static Analysis Error Showcase
#
#  This file contains INTENTIONAL errors that the static
#  analyzer catches at compile time (CHECK phase).
#
#  Run:
#    carton exec -- perl example/11_static_errors.pl 2>&1
#    carton exec -- perl bin/typist-check example/11_static_errors.pl
#
#  Errors appear as warnings on STDERR before "main" runs.
#  The program still executes because static-only mode (the
#  default) does not abort on type violations.
# ═══════════════════════════════════════════════════════════


# ── 1. Type Mismatches ──────────────────────────────────
#
# The type checker compares inferred types against declared
# types at variable initializers, assignments, call sites,
# and return positions.

sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }

# [TypeMismatch] argument: Str where Int expected
my $r1 = add("five", 3);

# [TypeMismatch] variable initializer
my $count :sig(Int) = "many";

# [TypeMismatch] return value
sub bad_return :sig(() -> Int) () {
    "not a number";
}


# ── 2. Arity Mismatches ────────────────────────────────
#
# Argument count must match the parameter list.
# Defaults and variadic (...Type) adjust the minimum.
# (Wrapped in sub — Perl's own arity check would abort at runtime.)

sub arity_errors :sig(() -> Void) () {
    # [ArityMismatch] too few
    my $r2 = add(1);

    # [ArityMismatch] too many
    my $r3 = add(1, 2, 3);
}


# ── 3. Effect Mismatches ───────────────────────────────
#
# Every effectful call must be covered by the caller's
# declared effects.  A pure function (no ![...]) may not
# call effectful code.

BEGIN {
    effect Logger => +{
        log => '(Str) -> Void',
    };
}

sub log_it :sig((Str) -> Void ![Logger]) ($msg) {
    Logger::log($msg);
}

# [EffectMismatch] pure function calls effectful function
sub pure_caller :sig((Str) -> Void) ($msg) {
    log_it($msg);
}


# ── 4. Protocol Violations ─────────────────────────────
#
# Protocols enforce operation ordering via finite state
# machines.  The static analyzer traces calls inside each
# function body and verifies state transitions.
#
# State machine for DB (* = ground/inactive):
#
#   * ──connect──→ Connected ──auth──→ Authenticated
#                                          ↕ query
#

BEGIN {
    effect DB => qw/Connected Authenticated/ => +{
        connect => protocol('(Str) -> Void',      '* -> Connected'),
        auth    => protocol('(Str, Str) -> Void', 'Connected -> Authenticated'),
        query   => protocol('(Str) -> Str',       'Authenticated -> Authenticated'),
    };
}

# ── 4a. Operation not allowed in current state ──────────
#
# query requires Authenticated, but we start in *.
#
# [ProtocolMismatch] operation 'query' is not allowed in state '*'

sub query_too_early :sig(() -> Str ![DB<*>]) () {
    DB::query("SELECT 1");
}

# ── 4b. Ends in wrong state ─────────────────────────────
#
# Declared DB<* -> Authenticated> but only connects
# (stops at Connected).
#
# [ProtocolMismatch] ends in state 'Connected' but declared end state is 'Authenticated'

sub incomplete_setup :sig(() -> Void ![DB<* -> Authenticated>]) () {
    DB::connect("localhost");
}

# ── 4c. Sub-call state mismatch ─────────────────────────
#
# do_auth expects Connected, but caller starts in *.
#
# [ProtocolMismatch] do_auth() expects state 'Connected' but current state is '*'

sub do_auth :sig(() -> Void ![DB<Connected -> Authenticated>]) () {
    DB::auth("admin", "secret");
}

sub bad_composition :sig(() -> Str ![DB<* -> Authenticated>]) () {
    do_auth();
    DB::query("SELECT 1");
}


# ── 5. Correct usage for comparison ─────────────────────
#
# No errors: all operations follow the protocol.

sub db_session :sig(() -> Str ![DB<* -> Authenticated>]) () {
    DB::connect("localhost");
    DB::auth("admin", "secret");
    DB::query("SELECT 1");
}


# ── main ─────────────────────────────────────────────────
#
# By the time we reach here, CHECK-phase warnings have
# already been emitted.  The program runs normally because
# static-only mode does not die on type violations.

say "── Static errors were reported above (STDERR) ──";
say "Program continues in static-only mode.";
