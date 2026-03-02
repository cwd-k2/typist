#!/usr/bin/env perl
use v5.40;
use lib 'lib';
use Typist -runtime;
use Typist::DSL;

# ═══════════════════════════════════════════════════════════
#  12 — Method Chains
#
#  Struct accessors, immutable updates, newtype ->base,
#  and their combinations in chains.
# ═══════════════════════════════════════════════════════════

# ── Setup: types ─────────────────────────────────────────

BEGIN {
    newtype ProductId => Int;

    struct Product => (name => Str, price => Int);

    struct Order => (
        id      => Alias('ProductId'),
        product => Alias('Product'),
        qty     => Int,
    );

    struct Customer => (
        name  => Str,
        age   => Int,
        email => optional(Str),
    );
}

# ── 1. Struct Accessor ──────────────────────────────────
#
# $obj->field reads the field value.

my $p = Product(name => "Widget", price => 1200);
say "name:  ", $p->name;     # Widget
say "price: ", $p->price;    # 1200

# ── 2. Immutable Update Chain ───────────────────────────
#
# ->with(field => val) returns a new instance.
# The original is unchanged — chain freely.

my $p2 = $p->with(price => 980);
say "updated price: ", $p2->price;   # 980
say "original:      ", $p->price;    # 1200

# Chain: update then access
my $name_after_update = $p->with(name => "Gadget")->name;
say "chained: ", $name_after_update; # Gadget

# ── 3. Newtype ->base ──────────────────────────────────
#
# Newtypes wrap a value in a nominal shell.
# ->base extracts the inner value.

my $pid = ProductId(42);
say "ProductId: ", $pid->base;       # 42

# ── 4. Struct → Newtype Chain ───────────────────────────
#
# When a struct field is a newtype, chain through both.

my $order = Order(
    id      => ProductId(7),
    product => Product(name => "Sprocket", price => 500),
    qty     => 3,
);

say "order id (raw): ", $order->id->base;       # 7
say "order product:  ", $order->product->name;   # Sprocket

# ── 5. Function Return Accessor ────────────────────────
#
# When a function returns a struct, call accessors on the result.

sub find_order :sig((Int) -> Order) ($n) {
    Order(
        id      => ProductId($n),
        product => Product(name => "Item-$n", price => $n * 100),
        qty     => 1,
    );
}

say "found: ", find_order(3)->product->name;     # Item-3
say "price: ", find_order(5)->product->price;    # 500

# ── 6. Optional Field Accessor ─────────────────────────
#
# Optional fields return undef when absent.
# Use // to provide a default.

my $c1 = Customer(name => "Alice", age => 30, email => 'alice@example.com');
my $c2 = Customer(name => "Bob",   age => 25);

say "email: ", $c1->email // "(none)";  # alice@example.com
say "email: ", $c2->email // "(none)";  # (none)
