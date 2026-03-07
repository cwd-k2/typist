# Domain Modeling

This page covers patterns for encoding domain knowledge in the type system: preventing value confusion with newtypes, building rich data models with structs, encoding state machines with ADTs, and composing these pieces into a coherent domain layer.

---

## Opaque Newtypes for IDs and Values

The most common domain modeling mistake is using raw `Int` or `Str` for everything. A `UserId` and an `OrderId` are both integers, but passing one where the other is expected is a bug. Newtypes catch this at the type level.

```typist
use v5.40;
use Typist;

BEGIN {
    newtype UserId    => 'Int';
    newtype OrderId   => 'Int';
    newtype ProductId => 'Str';
    newtype Price     => 'Int';    # cents, not dollars
    newtype Quantity  => 'Int';
}
```

Newtypes are nominal: `UserId` and `OrderId` both wrap `Int`, but they are distinct types. The static checker rejects mixing them:

```typist
sub find_user :sig((UserId) -> Str) ($id) {
    "User #" . UserId::coerce($id);
}

my $uid = UserId(42);
my $oid = OrderId(42);

find_user($uid);    # ok
find_user($oid);    # static error: expected UserId, got OrderId
find_user(42);      # static error: expected UserId, got Int
```

### Extracting the Inner Value

Use `Name::coerce($val)` to unwrap a newtype and get the raw value back:

```typist
my $uid = UserId(42);
my $raw = UserId::coerce($uid);    # 42 (plain Int)
```

This is intentionally explicit -- unwrapping should be a conscious decision at module boundaries, not something that happens silently.

### When to Use newtype vs typedef

| Mechanism | Semantics | Use case |
|-----------|-----------|----------|
| `typedef` | Structural alias (interchangeable) | Readability: `typedef Name => 'Str'` |
| `newtype` | Nominal wrapper (distinct type) | Safety: `newtype UserId => 'Int'` |

Use `typedef` when you want a shorter name for a complex type. Use `newtype` when confusion between values of the same underlying type would be a bug.

---

## Rich Domain Types with Structs

Structs are nominal, immutable, blessed record types. They give you a constructor, accessors, and immutable derivation out of the box.

```typist
BEGIN {
    struct Product => (
        id    => 'ProductId',
        name  => 'Str',
        price => 'Price',
        stock => 'Quantity',
        optional(description => 'Str'),
        optional(category    => 'Str'),
    );
}

my $widget = Product(
    id    => ProductId("W-001"),
    name  => "Widget",
    price => Price(1999),
    stock => Quantity(50),
);

say $widget->name;     # "Widget"
say $widget->price;    # Price object (use Price::coerce to get 1999)
```

### Optional Fields

Use `optional(field => 'Type')` for fields that may be omitted at construction time. Optional accessors return `undef` when the field was not provided:

```typist
my $w = Product(
    id    => ProductId("W-001"),
    name  => "Basic Widget",
    price => Price(999),
    stock => Quantity(100),
    # description and category omitted -- both optional
);

say $w->description;    # undef
```

### Immutable Derivation

Structs are immutable. To produce a modified copy, use `derive`:

```typist
my $updated = Product::derive($widget,
    price => Price(1499),
    stock => Quantity(45),
);

# $widget is unchanged; $updated has the new price and stock
```

### Generic Structs

Structs can be parameterized:

```typist
BEGIN {
    struct 'Pair[T, U]' => (fst => 'T', snd => 'U');
}

my $p = Pair(fst => 1, snd => "hello");
# Inferred as Pair[Int, Str]
```

### Bounded Generic Structs

Type parameters can carry bounds or typeclass constraints:

```typist
BEGIN {
    struct 'NumBox[T: Num]' => (value => 'T');
    struct 'ShowBox[T: Show]' => (value => 'T');
}

my $nb = NumBox(value => 42);       # ok: Int <: Num
my $sb = ShowBox(value => "hello");  # ok if instance Show => 'Str' exists
```

---

## State Machines with ADTs

Algebraic data types (ADTs) model values that can be one of several variants. Combined with `match`, they provide exhaustive pattern matching.

### Simple Status Enum

For pure enumeration (no payload), use `enum`:

```typist
BEGIN {
    enum Color => qw(Red Green Blue);
}

sub color_name :sig((Color) -> Str) ($c) {
    match $c,
        Red   => sub { "red" },
        Green => sub { "green" },
        Blue  => sub { "blue" };
}
```

### Rich State with Payloads

When variants carry data, use `datatype`:

```typist
BEGIN {
    datatype OrderStatus => (
        Created   => '()',
        Confirmed => '()',
        Shipped   => '(Str)',       # tracking number
        Delivered => '()',
        Cancelled => '(Str)',       # reason
    );
}

my $status = Shipped("TRACK-12345");

my $label = match $status,
    Created   => sub { "Pending" },
    Confirmed => sub { "Confirmed" },
    Shipped   => sub ($tracking) { "Shipped: $tracking" },
    Delivered => sub { "Delivered" },
    Cancelled => sub ($reason) { "Cancelled: $reason" };
```

### Parameterized ADTs

ADTs can be generic:

```typist
BEGIN {
    datatype 'Option[T]' => (
        Some => '(T)',
        None => '()',
    );

    datatype 'Result[T]' => (
        Ok  => '(T)',
        Err => '(Str)',
    );
}
```

### Exhaustiveness

If you omit a variant arm in `match` and there is no `_` fallback, the static checker and Perl::Critic policy `ExhaustivenessCheck` will warn. At runtime, an unmatched variant causes a `die`:

```typist
# Static warning: missing 'Cancelled' arm
my $msg = match $status,
    Created   => sub { "new" },
    Confirmed => sub { "confirmed" },
    Shipped   => sub ($t) { "shipped" },
    Delivered => sub { "done" };
    # Cancelled not handled -- warning
```

Add a `_` fallback to suppress the warning when you intentionally want a default:

```typist
my $msg = match $status,
    Shipped => sub ($t) { "In transit: $t" },
    _       => sub { "Other status" };
```

---

## Combining Newtypes, Structs, and ADTs

These building blocks compose naturally. A realistic domain model layers them:

```typist
BEGIN {
    # -- Newtypes for domain primitives
    newtype CustomerId => 'Int';
    newtype OrderId    => 'Int';
    newtype ProductId  => 'Str';
    newtype Price      => 'Int';    # cents
    newtype Quantity   => 'Int';

    # -- Structs for domain entities
    struct OrderItem => (
        product  => 'ProductId',
        quantity => 'Quantity',
        price    => 'Price',
    );

    struct Order => (
        id       => 'OrderId',
        customer => 'CustomerId',
        items    => 'ArrayRef[OrderItem]',
        status   => 'OrderStatus',
    );

    # -- ADTs for domain state
    datatype OrderStatus => (
        Created   => '()',
        Confirmed => '()',
        Fulfilled => '()',
        Cancelled => '(Str)',
    );
}
```

### Functions Over the Domain

```typist
sub order_total :sig((Order) -> Price) ($order) {
    my $total = 0;
    for my $item ($order->items->@*) {
        $total += Price::coerce($item->price) * Quantity::coerce($item->quantity);
    }
    Price($total);
}

sub cancel_order :sig((Order, Str) -> Order) ($order, $reason) {
    Order::derive($order, status => Cancelled($reason));
}

sub is_active :sig((Order) -> Bool) ($order) {
    match $order->status,
        Created   => sub { 1 },
        Confirmed => sub { 1 },
        Fulfilled => sub { 0 },
        Cancelled => sub ($r) { 0 };
}
```

### Recursive Types for Trees

```typist
BEGIN {
    struct Category => (
        name     => 'Str',
        optional(parent => 'Str'),
    );

    typedef CategoryTree => 'ArrayRef[{ category => Category, children => CategoryTree }]';
}

sub find_category :sig((CategoryTree, Str) -> Option[Category]) ($tree, $name) {
    for my $node ($tree->@*) {
        return Some($node->{category}) if $node->{category}->name eq $name;
        my $found = find_category($node->{children}, $name);
        return $found if match $found,
            Some => sub ($c) { 1 },
            None => sub { 0 };
    }
    None();
}
```

---

## Design Guidelines

1. **Start with newtypes for IDs and quantities.** This is the highest-value, lowest-effort change. It catches cross-domain confusion immediately.

2. **Use structs for entities, not bare hashrefs.** Structs give you immutability, accessors, field validation, and cross-file type resolution.

3. **Model state transitions with ADTs, not string constants.** `Cancelled("reason")` is self-documenting and exhaustively matchable. `"cancelled"` is not.

4. **Keep domain types in a dedicated module.** A `MyApp::Types` module that exports constructors via `@EXPORT` keeps type definitions centralized and reusable across your codebase (see [Multi-File Projects](multifile.md)).

5. **Prefer composition over inheritance.** Typist has no class hierarchy. Build complex types by composing newtypes, structs, and ADTs. If you need polymorphism, use type classes.
