# Multi-File Projects

Real projects span multiple files and packages. This page covers how to organize type definitions across modules, how cross-file type resolution works, and how to structure a project for clean type-level dependencies.

---

## Shared Type Definitions Module

The recommended pattern is a dedicated types module that defines all shared domain types and exports their constructors:

```perl
# lib/MyApp/Types.pm
package MyApp::Types;
use v5.40;
use Typist;
use Exporter 'import';
our @EXPORT = qw(UserId Email Product Order);

BEGIN {
    newtype UserId => 'Int';
    newtype Email  => 'Str';

    struct Product => (
        id    => 'Int',
        name  => 'Str',
        price => 'Int',
    );

    struct Order => (
        id         => 'Int',
        product_id => 'Int',
        quantity   => 'Int',
    );
}

1;
```

Key points:

- **`BEGIN` blocks** ensure types are registered before CHECK-phase analysis runs.
- **`@EXPORT`** exports constructor functions (`UserId(...)`, `Product(...)`) into the caller's namespace via Perl's standard Exporter mechanism.
- Type names in `:sig()` annotations are resolved from the Registry, not from `@EXPORT`. But constructors used as function calls in code do need to be exported.

---

## Consumer Modules

Modules that use these types import the types module:

```perl
# lib/MyApp/Service.pm
package MyApp::Service;
use v5.40;
use Typist;
use MyApp::Types;

sub find_product :sig((Int) -> Product) ($id) {
    Product(id => $id, name => "Widget", price => 100);
}

sub create_order :sig((Int, Int) -> Order ![IO]) ($product_id, $qty) {
    say "Creating order for product $product_id...";
    Order(id => 1, product_id => $product_id, quantity => $qty);
}

1;
```

When `MyApp::Service` says `use MyApp::Types`:

1. Perl runs `MyApp::Types::import()`, which exports constructor subs (`UserId`, `Product`, etc.) into the caller's namespace.
2. The `BEGIN` blocks in `MyApp::Types` have already executed, registering all types in the global Registry.
3. Type names like `Product` in `:sig((Int) -> Product)` are resolved by the static analyzer from the Registry.

---

## How Cross-File Type Resolution Works

### The Two Worlds

Typist operates in two distinct namespaces simultaneously:

| World | What it resolves | Mechanism |
|-------|-----------------|-----------|
| **Perl** | Constructor calls, subroutine calls, exported symbols | Standard `use`/`@EXPORT`/Exporter |
| **Typist** | Type names inside `:sig()`, field types in `struct`, etc. | Parser + Registry (string-based, global) |

Both are activated by `use`, but they work differently:

- **Perl imports** require `@EXPORT` and follow Perl's standard namespace rules. Without export, `Product(...)` as a function call will fail.
- **Typist type names** are available globally once registered via `BEGIN` blocks. The string `'Product'` in `:sig((Int) -> Product)` resolves via the Registry regardless of what is in `@EXPORT`.

### Synthetic Namespaces

Several Typist constructs create packages that have no corresponding `.pm` file:

| Construct | Created namespace | Example calls |
|-----------|------------------|---------------|
| `effect Logger => +{...}` | `Logger::` | `Logger::log(...)` |
| `typeclass Show => ...` | `Show::` | `Show::show(...)` |
| `newtype UserId => ...` | `UserId::` | `UserId::coerce(...)` |
| `struct Person => (...)` | `Person::` | `Person::derive(...)`, `$p->name()` |

These are created as side effects of executing `BEGIN` blocks. Any code loaded after the defining module can use these qualified calls directly -- no export needed.

### What Needs Exporting

| Item | Needs `@EXPORT`? | Why |
|------|:---:|------|
| Constructor functions (`Product(...)`) | Yes | Called as bare functions in Perl code |
| Type names in `:sig()` | No | Resolved from Registry strings |
| Qualified calls (`Logger::log(...)`) | No | Perl resolves `Package::sub` directly |
| Struct accessors (`$p->name`) | No | Method dispatch on blessed objects |

---

## The ImportHint Diagnostic

The static analyzer tracks which package defined each type (`Registry.set_defined_in`) and which packages the current file imports (from `use` statements). When a type name used in `:sig()` was defined in a package that is not reachable through the current file's `use` chain, an `ImportHint` diagnostic is emitted.

```
ImportHint: Type 'Product' (defined in MyApp::Types) used but 'MyApp::Types' is not imported
```

This is a hint (severity 4), not a hard error. The type still resolves via the global Registry. The diagnostic helps maintain explicit import discipline.

To resolve: add `use MyApp::Types;` to the consuming module.

---

## Project Layout

A typical multi-file Typist project:

```
lib/
  MyApp/
    Types.pm          # Shared newtypes, structs, ADTs, effects
    Types/
      Domain.pm       # Domain-specific types (optional split)
      Events.pm       # Event types
    Service.pm        # Business logic with :sig() annotations
    Repository.pm     # Data access layer
    Handler.pm        # Effect handlers / infrastructure
```

### Type Module Organization

For small projects, a single `Types.pm` is sufficient. As the project grows, split by concern:

```perl
# lib/MyApp/Types/Domain.pm
package MyApp::Types::Domain;
use v5.40;
use Typist;
use Exporter 'import';
our @EXPORT = qw(UserId ProductId Price Quantity Product Order OrderItem);

BEGIN {
    newtype UserId    => 'Int';
    newtype ProductId => 'Str';
    newtype Price     => 'Int';
    newtype Quantity  => 'Int';

    struct Product => (
        id    => 'ProductId',
        name  => 'Str',
        price => 'Price',
    );

    struct OrderItem => (
        product  => 'ProductId',
        quantity => 'Quantity',
        price    => 'Price',
    );

    struct Order => (
        id    => 'Int',
        items => 'ArrayRef[OrderItem]',
    );
}

1;
```

```perl
# lib/MyApp/Types/Events.pm
package MyApp::Types::Events;
use v5.40;
use Typist;
use Exporter 'import';
our @EXPORT = qw(OrderCreated OrderCancelled);

# Import domain types so we can reference them
use MyApp::Types::Domain;

BEGIN {
    datatype OrderEvent => (
        OrderCreated   => '(Order)',
        OrderCancelled => '(Int, Str)',    # order_id, reason
    );
}

1;
```

### Re-Exporting

A top-level module can re-export everything:

```perl
# lib/MyApp/Types.pm
package MyApp::Types;
use v5.40;
use Exporter 'import';

use MyApp::Types::Domain;
use MyApp::Types::Events;

our @EXPORT = (
    @MyApp::Types::Domain::EXPORT,
    @MyApp::Types::Events::EXPORT,
);

1;
```

---

## Cross-File Effects and Typeclasses

Effects and typeclasses follow the same pattern as types:

```perl
# lib/MyApp/Effects.pm
package MyApp::Effects;
use v5.40;
use Typist;

BEGIN {
    effect Logger => +{
        log => '(Str) -> Void',
    };

    effect DB => +{
        query      => '(Str) -> Str',
        execute    => '(Str) -> Int',
    };
}

1;
```

Consumer modules `use MyApp::Effects` and then use `Logger::log(...)` and `![Logger]` in `:sig()` annotations. No export is needed for effect operations -- they are installed as qualified subs in synthetic namespaces.

---

## Cross-File Typeclass Instances

Typeclass instances can be defined in any module:

```perl
# lib/MyApp/Instances.pm
package MyApp::Instances;
use v5.40;
use Typist;
use MyApp::Types::Domain;

BEGIN {
    instance Show => 'Product', +{
        show => sub ($p) { "Product(" . $p->name . ")" },
    };
}

1;
```

**Known limitation**: the static analyzer registers instance existence but does not verify method completeness across files. Instance completeness is checked at runtime. This is because cross-file loading order is non-deterministic during static analysis.

---

## LSP Workspace Support

The `typist-lsp` server provides cross-file support via the `Workspace` module. When you open a project, the LSP:

1. Scans all `.pm` files under the workspace root.
2. Extracts type definitions, function signatures, effects, typeclasses, and instances from each file.
3. Builds a shared Registry for cross-file resolution.
4. Updates incrementally when files change (`didSave`).

This gives you:

- **Cross-file hover**: hover over a type name to see its definition, even if it is defined in another file.
- **Cross-file go-to-definition**: jump to the source of a type, function, or effect.
- **Cross-file diagnostics**: type mismatches that involve types from other files are caught.
- **Cross-file completion**: struct fields, effect operations, and constructors from other files appear in completion lists.

The `typist-check` CLI uses the same Workspace for cross-file resolution.
