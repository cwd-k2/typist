# Debug Tools

Typist ships three diagnostic tools in `bin/debug/` for inspecting type inference, PPI parse trees, and registry contents. These are invaluable when investigating unexpected diagnostics or understanding how Typist sees your code.

---

## typist-infer-dump

Dumps inferred types for all variables in a source file — both annotated and inferred.

### Usage

```sh
typist-infer-dump lib/MyApp/Order.pm
typist-infer-dump --filter ok lib/MyApp/Order.pm
typist-infer-dump --scope fn:process lib/MyApp/Order.pm
typist-infer-dump --root src/ lib/MyApp/Order.pm
typist-infer-dump --no-color lib/MyApp/Order.pm
```

### Options

| Option | Description |
|--------|-------------|
| `--filter FILTER` | Show only variables matching a filter |
| `--scope SCOPE` | Limit to a scope: `top` (top-level) or `fn:NAME` (inside function) |
| `--root DIR` | Workspace root for cross-file resolution |
| `--no-color` | Disable colored output |

### Filters

| Filter | Meaning |
|--------|---------|
| `ok` | Successfully inferred (has a concrete type) |
| `undef` | Inference returned undef (could not determine type) |
| `Any_skip` | Inferred as `Any` (gradual typing bypass) |
| `no_init` | Variable has no initializer |
| `annotated` | Variable has an explicit `:sig()` annotation |

### Example Output

```
lib/MyApp/Order.pm

  fn:process
    $total     : Int          (inferred)
    $items     : ArrayRef[OrderItem]  (annotated)
    $discount  : Double       (inferred)

  fn:validate
    $result    : Result[Order] (inferred)
    $err       : Str          (inferred)

  top
    $config    : Config       (annotated)
```

This tool uses the same inference engine as the static analyzer, so the types shown are exactly what Typist uses for type checking.

---

## typist-ppi-dump

Visualizes the PPI abstract syntax tree for a Perl source file. Useful for understanding how PPI parses your code — particularly when debugging extractor issues or understanding why a construct isn't being recognized.

### Usage

```sh
typist-ppi-dump lib/MyApp/Order.pm
typist-ppi-dump --line 42 lib/MyApp/Order.pm
typist-ppi-dump --range 10-20 lib/MyApp/Order.pm
typist-ppi-dump --tokens lib/MyApp/Order.pm
typist-ppi-dump --siblings lib/MyApp/Order.pm
typist-ppi-dump --depth 3 lib/MyApp/Order.pm
```

### Options

| Option | Description |
|--------|-------------|
| `--line N` | Show the innermost statement containing line N |
| `--range M-N` | Show statements spanning lines M through N |
| `--tokens` | Flat token list instead of tree view |
| `--siblings` | Show sibling relationships |
| `--depth D` | Maximum tree depth to display |

### Example Output (Tree View)

```
PPI::Document
  PPI::Statement::Sub
    PPI::Token::Word              'sub'
    PPI::Token::Word              'add'
    PPI::Token::Attribute         'sig((Int, Int) -> Int)'
    PPI::Token::Prototype         '($a, $b)'
    PPI::Structure::Block         { ... }
      PPI::Statement::Expression
        PPI::Token::Symbol        '$a'
        PPI::Token::Operator      '+'
        PPI::Token::Symbol        '$b'
```

### Example Output (Tokens)

```
L5   Word          'sub'
L5   Word          'add'
L5   Attribute     'sig((Int, Int) -> Int)'
L5   Prototype     '($a, $b)'
L5   Structure     '{ ... }'
```

!!! tip
    PPI parses anonymous sub signatures as `PPI::Token::Prototype`, not `PPI::Structure::List`. If you see unexpected behavior with anonymous subs, check the PPI tree to understand what Typist's extractor is working with.

---

## typist-registry-dump

Dumps the workspace registry contents after scanning a file or directory. Shows what types, functions, effects, and other symbols Typist has registered.

### Usage

```sh
typist-registry-dump lib/MyApp/Order.pm
typist-registry-dump --section functions lib/MyApp/Order.pm
typist-registry-dump --section types lib/MyApp/Order.pm
typist-registry-dump --package MyApp::Order lib/MyApp/Order.pm
typist-registry-dump --name find_product lib/MyApp/Order.pm
```

### Options

| Option | Description |
|--------|-------------|
| `--section SECTION` | Show only a specific registry section |
| `--package PKG` | Filter by package name |
| `--name NAME` | Filter by symbol name |

### Sections

| Section | Contents |
|---------|----------|
| `functions` | Registered function signatures |
| `types` | Type aliases (typedef) |
| `datatypes` | Algebraic data types (datatype/enum) |
| `typeclasses` | Type class definitions |
| `effects` | Effect definitions |
| `structs` | Struct definitions |
| `instances` | Type class instances |

### Example Output

```
=== functions ===
MyApp::Order::create_order
  params:  (ProductId, Quantity) -> Order
  effects: ![IO]

MyApp::Order::validate
  params:  (Order) -> Result[Order]
  effects: (pure)

=== types ===
Price = Int
OrderId = newtype(Int)

=== structs ===
Order
  id       : OrderId
  product  : ProductId
  quantity : Quantity
  status   : OrderStatus

=== effects ===
Logger
  log : (Str) -> Void
```

---

## When to Use Each Tool

| Situation | Tool |
|-----------|------|
| "Why does Typist think `$x` is `Any`?" | `typist-infer-dump --filter Any_skip` |
| "Why isn't my `:sig()` being picked up?" | `typist-ppi-dump --line N` to see how PPI parses it |
| "Is my typedef registered correctly?" | `typist-registry-dump --section types` |
| "What type does Typist infer for this variable?" | `typist-infer-dump --scope fn:NAME` |
| "Why does this function call fail arity check?" | `typist-ppi-dump` to see how args are parsed |
| "Are cross-file types visible?" | `typist-registry-dump --root .` to see merged registry |
