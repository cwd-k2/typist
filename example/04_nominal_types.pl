#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  04 — Nominal Types
#
#  newtype creates distinct types with the same internal
#  representation. Unlike typedef (structural alias),
#  newtypes are NOT interchangeable — UserId ≠ OrderId
#  even though both wrap Int.
#
#  Also: literal types and recursive type definitions.
# ═══════════════════════════════════════════════════════════

# ── Newtype ───────────────────────────────────────────────
#
# newtype Name => InnerType
#
# Creates a constructor (Name($val)) and registers the
# nominal type. unwrap($val) extracts the inner value.
# Boundary enforcement is ALWAYS active, even without -runtime.

BEGIN {
    newtype UserId  => Int;
    newtype OrderId => Int;
    newtype Email   => Str;
}

my $uid = UserId(42);
my $oid = OrderId(99);
my $em  = Email('alice@example.com');

say "UserId:  ", unwrap($uid);     # 42
say "OrderId: ", unwrap($oid);     # 99
say "Email:   ", unwrap($em);

# Constructor validates inner type
eval { UserId("hello") };
say "UserId('hello'):    $@" if $@;

eval { Email(42) };
say "Email(42):          $@" if $@;

# Newtypes are NOT interchangeable
my $x :Type(UserId) = UserId(1);

eval { $x = OrderId(1) };          # same inner value, different type
say "UserId <- OrderId:  $@" if $@;

eval { $x = 1 };                   # raw Int is not UserId
say "UserId <- raw Int:  $@" if $@;

# ── Newtypes in Function Signatures ──────────────────────
#
# Functions that accept UserId will reject OrderId and raw Int.

sub find_user :Type((UserId) -> Str) ($id) {
    "User #" . unwrap($id);
}

say find_user(UserId(42));

eval { find_user(OrderId(42)) };
say "find_user(OrderId): $@" if $@;

eval { find_user(42) };
say "find_user(42):      $@" if $@;

# ── Literal Types ─────────────────────────────────────────
#
# Singleton types: only the exact value is accepted.
# Useful for status codes, flags, and discriminated unions.

my $answer :Type(42) = 42;
say "answer: $answer";

eval { $answer = 43 };
say "42 <- 43:   $@" if $@;

eval { $answer = 0 };
say "42 <- 0:    $@" if $@;

# String literals
my $status :Type("ok" | "error") = "ok";
say "status: $status";

$status = "error";                  # ok
say "status: $status";

eval { $status = "warning" };
say '"ok"|"error" <- "warning":  ' . $@ if $@;

# ── Recursive Types ──────────────────────────────────────
#
# Self-referential typedef using Alias() for lazy resolution.
# The recursion must be productive — always through a constructor.

BEGIN {
    typedef JsonValue =>
        Str | Num | Bool | Undef
        | ArrayRef(Alias('JsonValue'))
        | HashRef(Str, Alias('JsonValue'));
}

my $json :Type(JsonValue) = +{
    name   => "Alice",
    scores => [100, 95, 88],
    meta   => +{ active => 1, tags => ["admin", "user"] },
};
say "json: valid nested structure";

# Leaves: all valid JsonValue types
my $j1 :Type(JsonValue) = "hello";
my $j2 :Type(JsonValue) = 42;
my $j3 :Type(JsonValue) = undef;
my $j4 :Type(JsonValue) = [1, "two", [3]];
say "json leaves: ok";

# CodeRef is not a valid JsonValue
eval { my $bad :Type(JsonValue) = sub { 1 } };
say "JsonValue <- CodeRef:  $@" if $@;

# ── Combining Newtype and Struct ──────────────────────────

BEGIN {
    typedef Account => Struct(
        id    => Alias('UserId'),
        email => Alias('Email'),
        name  => Str,
    );
}

my $acct :Type(Account) = +{
    id    => UserId(1),
    email => Email('alice@example.com'),
    name  => "Alice",
};
say "account: $acct->{name} (", unwrap($acct->{id}), ")";

# Raw values rejected in struct fields
eval {
    my $bad :Type(Account) = +{
        id    => 1,                     # needs UserId(1)
        email => 'alice@example.com',   # needs Email(...)
        name  => "Alice",
    };
};
say "Account raw fields:  $@" if $@;
