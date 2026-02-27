#!/usr/bin/env perl
use v5.40;
use lib 'lib', 'example/realworld/lib';
use Typist;
use Typist::DSL;
use Shop::Types;
use Shop::Inventory;
use Shop::Order;

# ═══════════════════════════════════════════════════
#  Realworld Example — Multi-file Shop System
#
#  Demonstrates cross-module type checking:
#  typedef, newtype, effect, typeclass across files.
# ═══════════════════════════════════════════════════

say "══ Success Cases ═════════════════════════════";
say "";

# ── Product Registration ───────────────────────

my $p1 = +{
    id    => ProductId("P001"),
    name  => "Widget",
    price => 1500,
    stock => 50,
};

my $p2 = +{
    id    => ProductId("P002"),
    name  => "Gadget",
    price => 3200,
    stock => 20,
};

Shop::Inventory::add_product($p1);
Shop::Inventory::add_product($p2);
say "Products registered: Widget, Gadget";

# ── Inventory Lookup ───────────────────────────

my $found = Shop::Inventory::find_product(ProductId("P001"));
say "Found: $found->{name} (\$", $found->{price}, ")";

my $avail = Shop::Inventory::in_stock(ProductId("P001"), 10);
say "P001 in stock (10): ", $avail ? "yes" : "no";

# ── Order Creation ─────────────────────────────

my $order = Shop::Order::create_order(
    OrderId(1),
    [
        +{ product_id => ProductId("P001"), quantity => 2 },
        +{ product_id => ProductId("P002"), quantity => 1 },
    ],
);

say "Order #", unwrap($order->{id}), " total: \$", $order->{total};

# ── TypeClass Dispatch (cross-module) ──────────

say "Printable(42):      ", Typist::TC::Printable::display(42);
say "Printable('hello'): ", Typist::TC::Printable::display("hello");

say "";
say "══ Type Error Demonstrations ════════════════";
say "";

# ── 1. Raw Str where ProductId expected ────────

say "── 1. Raw Str vs ProductId ──────────────────";
eval { Shop::Inventory::find_product("P001") };
say "find_product('P001'): $@" if $@;

# ── 2. ProductId where OrderId expected ────────

say "── 2. ProductId vs OrderId ──────────────────";
eval {
    Shop::Order::create_order(
        ProductId("P001"),
        [+{ product_id => ProductId("P001"), quantity => 1 }],
    );
};
say "create_order(ProductId(...)): $@" if $@;

# ── 3. Missing required field in Product ───────

say "── 3. Missing field in Product struct ───────";
eval {
    Shop::Inventory::add_product(+{
        id   => ProductId("P003"),
        name => "Broken",
    });
};
say "Product w/o price,stock: $@" if $@;

# ── 4. Wrong field type in Product ─────────────

say "── 4. Wrong field type in Product ───────────";
eval {
    Shop::Inventory::add_product(+{
        id    => ProductId("P004"),
        name  => "Bad",
        price => "free",
        stock => 10,
    });
};
say "Product price='free': $@" if $@;

# ── 5. Invalid OrderItem in array ──────────────

say "── 5. Invalid OrderItem in array ────────────";
eval {
    Shop::Order::create_order(
        OrderId(2),
        [+{ product_id => ProductId("P001") }],
    );
};
say "OrderItem w/o quantity: $@" if $@;

# ── 6. Non-array where ArrayRef expected ───────

say "── 6. Non-array for ArrayRef[OrderItem] ─────";
eval {
    Shop::Order::create_order(OrderId(3), "not an array");
};
say "create_order(..., 'not an array'): $@" if $@;

# ── 7. Wrong quantity type ─────────────────────

say "── 7. Wrong quantity type ───────────────────";
eval {
    Shop::Order::create_order(
        OrderId(4),
        [+{ product_id => ProductId("P001"), quantity => "lots" }],
    );
};
say "quantity='lots': $@" if $@;

# ── 8. TypeClass dispatch on unsupported type ──

say "── 8. TypeClass on unsupported type ─────────";
eval { Typist::TC::Printable::display([1, 2, 3]) };
say "Printable([1,2,3]): $@" if $@;

# ── 9. Newtype constructor with wrong inner ────

say "── 9. Newtype constructor violation ─────────";
eval { OrderId("not a number") };
say "OrderId('not a number'): $@" if $@;

# ── 10. Typed variable across modules ──────────

say "── 10. Typed variable boundary ──────────────";
my $pid :Type(ProductId) = ProductId("X001");
eval { $pid = "raw string" };
say "ProductId var <- raw Str: $@" if $@;

eval { $pid = OrderId(999) };
say "ProductId var <- OrderId: $@" if $@;

say "";
say "All demonstrations complete.";
