# Gradual Migration

Typist is designed for incremental adoption. You do not need to annotate your entire codebase at once. This page walks through a step-by-step migration of existing Perl code, from zero annotations to a fully typed module.

---

## Migration Strategy

The recommended order:

1. **Add `use Typist;`** to your modules -- runtime helpers only, no behavior change.
2. **Define domain types** -- `typedef`, `newtype`, `struct` for your data models.
3. **Annotate public API functions** -- start at module boundaries.
4. **Set up `typist-check` in CI** -- catch regressions early.
5. **Set up the LSP** -- get diagnostics as you code.
6. **Annotate effects** -- track I/O and exceptions.
7. **Work inward** -- annotate internal functions as needed.
8. **Consider `-runtime` for tests** -- catch boundary violations at test time.

Each step is independently valuable. You can stop at any point and still benefit from what you have annotated so far.

---

## Gradual Typing Semantics

Typist enforces checks proportional to annotation density:

| Annotation level | What happens |
|-----------------|-------------|
| **Fully annotated** | All type checks, effect checks, arity checks active |
| **Partially annotated** | Checked where annotations exist; untyped areas return `Any` |
| **Completely unannotated** | Treated as `(Any...) -> Any`; type checks skip; effects treated as pure |

The key principle: **no annotation = no constraint**. Adding `use Typist` without any `:sig()` annotations produces zero diagnostics and zero overhead.

---

## Before: Untyped Module

Here is a typical Perl module before any Typist integration:

```typist
# lib/MyApp/Pricing.pm
package MyApp::Pricing;
use v5.40;
use Exporter 'import';
our @EXPORT_OK = qw(calculate_total apply_discount format_price);

sub calculate_total ($items) {
    my $total = 0;
    for my $item (@$items) {
        $total += $item->{price} * $item->{quantity};
    }
    $total;
}

sub apply_discount ($total, $discount_pct) {
    my $discount = int($total * $discount_pct / 100);
    $total - $discount;
}

sub format_price ($cents) {
    sprintf '$%.2f', $cents / 100;
}

1;
```

Nothing is wrong with this code. It works. But there is no way to know, from the source alone, what `$items` should contain, what types `apply_discount` expects, or what any of these functions return.

---

## Step 1: Add `use Typist`

```typist
package MyApp::Pricing;
use v5.40;
use Typist;                        # <-- added
use Exporter 'import';
our @EXPORT_OK = qw(calculate_total apply_discount format_price);

# ... rest unchanged
```

This does nothing visible. No diagnostics, and almost no runtime cost. It enables `:sig()` attributes, runtime helpers, and the prelude. Static analysis remains explicit via `typist-check`, the LSP, or `use Typist -check;`.

---

## Step 2: Define Domain Types

Add a `BEGIN` block with type definitions that describe your domain:

```typist
package MyApp::Pricing;
use v5.40;
use Typist;
use Exporter 'import';
our @EXPORT_OK = qw(calculate_total apply_discount format_price);

BEGIN {                             # <-- added
    typedef LineItem => '{ price => Int, quantity => Int }';
}

# ... rest unchanged
```

For a larger project, put shared types in a dedicated module (see [Multi-File Projects](multifile.md)).

---

## Step 3: Annotate Public Functions

Start with the module's public API -- the functions that callers depend on:

```typist
sub calculate_total :sig((ArrayRef[LineItem]) -> Int) ($items) {
    my $total = 0;
    for my $item (@$items) {
        $total += $item->{price} * $item->{quantity};
    }
    $total;
}

sub apply_discount :sig((Int, Int) -> Int) ($total, $discount_pct) {
    my $discount = int($total * $discount_pct / 100);
    $total - $discount;
}

sub format_price :sig((Int) -> Str) ($cents) {
    sprintf '$%.2f', $cents / 100;
}
```

Now the static checker can verify:
- Callers pass the right types to these functions.
- Return types match the declared signatures.
- `$items` elements are used consistently with the `LineItem` record shape.

---

## Step 4: Strengthen Types with Newtypes

As confidence grows, promote raw types to newtypes for stronger guarantees:

```typist
BEGIN {
    newtype Price    => 'Int';    # cents
    newtype Quantity => 'Int';
    newtype Percent  => 'Int';    # 0-100

    struct LineItem => (
        price    => 'Price',
        quantity => 'Quantity',
    );
}

sub calculate_total :sig((ArrayRef[LineItem]) -> Price) ($items) {
    my $total = 0;
    for my $item (@$items) {
        $total += Price::coerce($item->price) * Quantity::coerce($item->quantity);
    }
    Price($total);
}

sub apply_discount :sig((Price, Percent) -> Price) ($total, $discount_pct) {
    my $raw = Price::coerce($total);
    my $discount = int($raw * Percent::coerce($discount_pct) / 100);
    Price($raw - $discount);
}

sub format_price :sig((Price) -> Str) ($cents) {
    sprintf '$%.2f', Price::coerce($cents) / 100;
}
```

Now `apply_discount(Price(1000), Quantity(5))` is a static error -- you cannot accidentally pass a quantity where a percentage is expected.

---

## After: Fully Typed Module

The complete migrated module:

```typist
# lib/MyApp/Pricing.pm
package MyApp::Pricing;
use v5.40;
use Typist;
use Exporter 'import';
our @EXPORT_OK = qw(
    Price Quantity Percent LineItem
    calculate_total apply_discount format_price
);

BEGIN {
    newtype Price    => 'Int';
    newtype Quantity => 'Int';
    newtype Percent  => 'Int';

    struct LineItem => (
        price    => 'Price',
        quantity => 'Quantity',
    );
}

sub calculate_total :sig((ArrayRef[LineItem]) -> Price) ($items) {
    my $total = 0;
    for my $item (@$items) {
        $total += Price::coerce($item->price) * Quantity::coerce($item->quantity);
    }
    Price($total);
}

sub apply_discount :sig((Price, Percent) -> Price) ($total, $discount_pct) {
    my $raw = Price::coerce($total);
    my $discount = int($raw * Percent::coerce($discount_pct) / 100);
    Price($raw - $discount);
}

sub format_price :sig((Price) -> Str) ($cents) {
    sprintf '$%.2f', Price::coerce($cents) / 100;
}

1;
```

---

## Setting Up CI

Add `typist-check` to your CI pipeline to catch type regressions:

```yaml
# GitHub Actions
- name: Type check
  run: typist-check --no-color

# Or with specific files
- name: Type check
  run: typist-check --no-color lib/MyApp/Pricing.pm lib/MyApp/Order.pm
```

Exit codes:
- `0` -- all clean
- `1` -- errors found (type mismatches, arity mismatches, etc.)
- `2` -- warnings only (undeclared type variables, unknown types, etc.)

Color is auto-disabled when stdout is not a TTY, so `--no-color` is optional in CI environments, but explicit is clearer.

---

## Setting Up the LSP

Configure your editor to use `typist-lsp` for real-time feedback. See [Editor Setup](../getting-started/editor-setup.md) for Neovim, VS Code, and other editor configurations.

If you opt into CHECK-phase analysis with `TYPIST_CHECK=1` or `use Typist -check;`, set `TYPIST_CHECK_QUIET=1` to suppress duplicate output when the LSP is providing the same diagnostics inline.

---

## Annotating Effects

Once your data types and function signatures are in place, add effect annotations to track side effects:

```typist
BEGIN {
    effect Logger => +{
        log => '(Str) -> Void',
    };
}

sub process_order :sig((Order) -> Price ![Logger, IO]) ($order) {
    Logger::log("Processing order " . $order->id);
    my $total = calculate_total($order->items);
    say "Order total: " . format_price($total);
    $total;
}
```

The static checker will flag callers of `process_order` that do not declare `Logger` and `IO` in their own effect rows.

---

## Using `-runtime` in Tests

For test suites, consider enabling runtime mode to catch violations at the boundary between typed and untyped code:

```typist
# t/pricing.t
use v5.40;
use Typist -runtime;
use MyApp::Pricing qw(Price Quantity LineItem calculate_total);

my $items = [
    LineItem(price => Price(1000), quantity => Quantity(2)),
    LineItem(price => Price(500),  quantity => Quantity(3)),
];

my $total = calculate_total($items);
# Runtime mode validates that $total is actually a Price
```

This adds per-call type checking overhead but catches bugs at the exact point of violation, which is valuable in tests.

---

## Tips for Gradual Migration

1. **Start at the edges.** Annotate module boundaries (public API functions) first. These are where type confusion most often manifests.

2. **Let the tooling guide you.** After annotating a few functions, run `typist-check` or open the file in your editor with the LSP. The diagnostics will point to the next places that need attention.

3. **Do not fight `Any`.** If the type checker infers `Any` for something, that is fine. It means the area is not yet annotated. Come back to it later.

4. **Newtypes pay for themselves immediately.** Even a single `newtype UserId => 'Int'` prevents an entire class of bugs. These are the highest-value annotations.

5. **One module at a time.** Migrate one module fully before moving to the next. A partially annotated module still provides value at its boundaries.

6. **Test `-runtime` selectively.** Do not enable `-runtime` in production code. Use it in test files where the overhead is acceptable and the additional checking is valuable.
