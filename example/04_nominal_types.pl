#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;

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
# nominal type. Name::coerce($val) extracts the inner value.
# Boundary enforcement is ALWAYS active, even without -runtime.

BEGIN {
    newtype UserId  => 'Int';
    newtype OrderId => 'Int';
    newtype Email   => 'Str';
}

my $uid = UserId(42);
my $oid = OrderId(99);
my $em  = Email('alice@example.com');

say "UserId:  ", UserId::coerce($uid);     # 42
say "OrderId: ", OrderId::coerce($oid);   # 99
say "Email:   ", Email::coerce($em);

# Constructor validates inner type
eval { UserId("hello") };
say "UserId('hello'):    $@" if $@;

eval { Email(42) };
say "Email(42):          $@" if $@;

# Newtypes are NOT interchangeable
my $x :sig(UserId) = UserId(1);

eval { $x = OrderId(1) };          # same inner value, different type
say "UserId <- OrderId:  $@" if $@;

eval { $x = 1 };                   # raw Int is not UserId
say "UserId <- raw Int:  $@" if $@;

# ── Newtypes in Function Signatures ──────────────────────
#
# Functions that accept UserId will reject OrderId and raw Int.

sub find_user :sig((UserId) -> Str) ($id) {
    "User #" . UserId::coerce($id);
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

my $answer :sig(42) = 42;
say "answer: $answer";

eval { $answer = 43 };
say "42 <- 43:   $@" if $@;

eval { $answer = 0 };
say "42 <- 0:    $@" if $@;

# String literals
my $status :sig("ok" | "error") = "ok";
say "status: $status";

$status = "error";                  # ok
say "status: $status";

eval { $status = "warning" };
say '"ok"|"error" <- "warning":  ' . $@ if $@;

# ── Recursive Types ──────────────────────────────────────
#
# Self-referential typedef using string form for lazy resolution.
# The recursion must be productive — always through a constructor.

BEGIN {
    typedef JsonValue => 'Str | Num | Bool | Undef | ArrayRef[JsonValue] | HashRef[Str, JsonValue]';
}

my $json :sig(JsonValue) = +{
    name   => "Alice",
    scores => [100, 95, 88],
    meta   => +{ active => 1, tags => ["admin", "user"] },
};
say "json: valid nested structure";

# Leaves: all valid JsonValue types
my $j1 :sig(JsonValue) = "hello";
my $j2 :sig(JsonValue) = 42;
my $j3 :sig(JsonValue) = undef;
my $j4 :sig(JsonValue) = [1, "two", [3]];
say "json leaves: ok";

# CodeRef is not a valid JsonValue
eval { my $bad :sig(JsonValue) = sub { 1 } };
say "JsonValue <- CodeRef:  $@" if $@;

# ── Combining Newtype and Struct ──────────────────────────

BEGIN {
    typedef Account => '{ id => UserId, email => Email, name => Str }';
}

my $acct :sig(Account) = +{
    id    => UserId(1),
    email => Email('alice@example.com'),
    name  => "Alice",
};
say "account: $acct->{name} (", UserId::coerce($acct->{id}), ")";

# Raw values rejected in struct fields
eval {
    my $bad :sig(Account) = +{
        id    => 1,                     # needs UserId(1)
        email => 'alice@example.com',   # needs Email(...)
        name  => "Alice",
    };
};
say "Account raw fields:  $@" if $@;
