# Conventions

> Canonical reference for Typist coding conventions, design patterns, and known Perl gotchas.
> For architecture overview, see [architecture.md](architecture.md).
> For type system reference, see the [Guide](../guide/index.md).
> For static analysis internals, see [static-analysis.md](static-analysis.md).

## Table of Contents

- [Language and Module Conventions](#language-and-module-conventions)
- [Type System Conventions](#type-system-conventions)
- [Static-First Design](#static-first-design)
- [Syntax Conventions](#syntax-conventions)
- [Feature Reference](#feature-reference)
- [Namespace Model](#namespace-model)
- [Design Principles](#design-principles)
- [Perl Gotchas](#perl-gotchas)
- [Cross-References](#cross-references)

---

## Language and Module Conventions

- All modules use `use v5.40` and subroutine signatures (`($self, $arg, ...)`).
- No source filters or external preprocessors. The system relies entirely on standard Perl attributes and PPI parsing for static analysis.
- Sub wrapping uses direct glob assignment to replace the original subroutine.

---

## Type System Conventions

### Immutable Type Nodes

Type nodes are immutable value objects. The `substitute` method returns a new node rather than mutating in place.

### Flyweight Atoms

Atom types use a flyweight pool (`%POOL`) for singleton semantics. Every reference to `Int` within a process points to the same object.

### Normalized Constructors

Union and Intersection constructors normalize their members by flattening nested unions/intersections and deduplicating members.

### Two-Tier Composite Types

- **Record** -- structural, plain hashrefs via `typedef Name => Record(...)`.
- **struct** -- nominal, blessed immutable objects via `struct Name => (fields...)`.
  - Constructors: `Name(field => val)`
  - Accessors: `$obj->field`
  - Immutable derive: `Name::derive($obj, field => val)`
  - `optional(field => Type)` marks fields that can be omitted (returns `("field?", Type)` pair, flattened into field list).
- Subtyping: `Struct <: Record` (structural compatibility), but `Record </: Struct` (nominal barrier).

### Two-Tier Collection Types

- **Array[T] / Hash[K,V]** -- list types. These are what `grep`, `map`, `sort`, and `@deref` produce (Perl's list context).
- **ArrayRef[T] / HashRef[K,V]** -- scalar reference types. These are what `[LIST]` and `+{LIST}` produce.
- `[Array[T]]` flattens to `ArrayRef[T]`.
- Array and Hash are NOT subtypes of ArrayRef/HashRef -- they are fundamentally different (list vs reference).

### TypeClass Dispatch Namespace

TypeClass dispatch installs into the caller's namespace (`${caller}::${ClassName}::${method}`), not into `Typist::TC::*`.

---

## Static-First Design

### Default Mode

`use Typist;` installs runtime helpers and the prelude only. No static analysis runs by default, and original subs execute directly with no tie and no wrappers.

### Runtime Mode

`use Typist -runtime;` (or `TYPIST_RUNTIME=1`) additionally enables `Tie::Scalar` variable monitoring on `:sig()` annotated variables.

### Structural Enforcement (Always Active)

Constructors always perform cheap structural checks, regardless of `-runtime`:

- **newtype**: creates blessed scalar reference. `Name::coerce($val)` extracts the inner value.
- **datatype**: argument count must match variant definition.
- **struct**: unknown field and missing required field checks.
- **Effect dispatch**: `Effect::op(@args)` dispatches to the nearest handler on the runtime stack.

Type validation (`contains`, `infer_value`, bounds, typeclass constraints) in constructors requires `-runtime`.

### CHECK Phase

The CHECK phase runs both structural checks (`Checker`) and full static analysis (`Analyzer` with `TypeChecker` + `EffectChecker`) per loaded package. Diagnostics surface as `warn` to STDERR, which perlnavigator picks up.

If you opt into CHECK analysis, suppress duplicate terminal diagnostics with `TYPIST_CHECK_QUIET=1` when using `typist-lsp`.

### Gradual Typing

Annotation density determines check strictness:

- **Fully annotated** -- all checks enforced.
- **Partially annotated** (some `:sig()`, no `:Eff`) -- pure effect assumed, return type unknown if no `:Returns`.
- **Completely unannotated** -- `(Any...) -> Any`, type checks skip, effect treated as pure (no constraint).

```
Mechanism             | use Typist (default) | use Typist -runtime
----------------------|----------------------|---------------------
Static Analysis       | ON                   | ON
CHECK diagnostics     | ON                   | ON
Structural checks     | ON                   | ON
Effect dispatch       | ON                   | ON
Typeclass dispatch    | ON                   | ON
Constructor type val. | OFF                  | ON
Tie::Scalar           | OFF                  | ON
```

---

## Syntax Conventions

### Hashref Literals

Always use `+{}` to disambiguate from blocks:

```typist
my $config = +{ host => "localhost", port => 8080 };
```

### String Syntax for Signatures

Typeclass and effect definitions use string syntax for method/operation signatures, consistent with `:sig()` annotations:

```typist
show => '(T) -> Str'
```

The Extractor only captures `PPI::Token::Quote`, so programmatic type constructors do not work for static analysis.

### String-Based Type Declarations

`use Typist` enables the type system and exports all core functions (`typedef`, `newtype`, `struct`, `optional`, etc.). All type declarations use strings:

```typist
use Typist;
typedef Name   => 'Str';
struct Person  => (name => 'Str', age => 'Int', optional(email => 'Str'));
instance Show  => 'Int', +{ show => sub ($x) { "$x" } };
```

No separate imports are needed for type names — they are resolved from strings by the Parser and Registry.

### Unified `:sig()` Annotation

```typist
sub add :sig(<T: Num>(T, T) -> T ![Console]) ($a, $b) { ... }
```

- Generics in `<>`.
- Arrow `->` separates parameters from return type.
- `![...]` introduces the effect row (brackets are required).

### LSP Coverage Rule

When adding or modifying static analysis features, update `docs/lsp-coverage.md`. New analysis outputs must have corresponding LSP entries (or an explicit "N/A" with rationale).

---

## Feature Reference

### Algebraic Data Types (ADT)

```typist
datatype Shape => Circle => '(Int)', Rectangle => '(Int, Int)';
```

Constructors are installed into the caller's namespace. Parameterized ADTs:

```typist
datatype 'Option[T]' => Some => '(T)', None => '()';
```

Type params are promoted from aliases to Var objects. Subtyping is covariant in type arguments.

### GADT

```typist
datatype 'Expr[A]' => IntLit => '(Int) -> Expr[Int]', BoolLit => '(Bool) -> Expr[Bool]';
```

Constructors with `->` specify per-constructor return types. Provides `is_gadt` predicate and `constructor_return_type($tag)` accessor.

### Enum

```typist
enum Color => qw(Red Green Blue);
```

Sugar for `datatype` with all zero-argument variants.

### Pattern Matching

```typist
match $value, Tag => sub (...) { ... }, _ => sub { ... };
```

Dispatches on `_tag`, splats `_values` into handlers. `_` is the optional fallback arm. Emits exhaustiveness warnings for registered ADTs when arms are incomplete and no fallback is given.

### Effects

```typist
effect Console => +{ writeLine => '(Str) -> Void' };
```

Operations are auto-installed as qualified subs (`Console::writeLine(@args)`), dispatching to the nearest handler on the runtime stack.

### Bounded Effect Generics

```typist
effect 'Counter[S: Num]' => +{
    get => '() -> S',
    add => '(S) -> Void',
};
```

Type parameters on effects support the same bound syntax as functions and structs: type bounds (`S: Num`), typeclass constraints (`T: Show`), or compound (`T: Num + Ord`). The Checker validates type arguments against bounds at the annotation site — `![Counter[Str]]` produces a `TypeMismatch` because `Str` is not a subtype of `Num`.

### Effect Protocols

```typist
effect DB => qw/Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', '* -> Connected'),
    query      => protocol('(Str) -> Str',  'Authed -> Authed'),
    disconnect => protocol('() -> Void',    'Authed -> *'),
};
```

`*` is the ground state (protocol inactive). Only active states appear in the states list. A function that begins a protocol session transitions from `*`:

```typist
sub start_session :sig(() -> Void ![DB<* -> Connected>]) ($self) { ... }
```

Mid-protocol functions may use any valid active state as `From`:

```typist
sub run_query :sig((Str) -> Str ![DB<Authed>]) ($self, $q) { ... }
```

Annotation: `![DB<* -> Authed>]` declares start/end states. `![DB<Authed>]` is invariant. `![DB]` defaults to `* -> *` (full session cycle). ProtocolChecker traces operation sequences and verifies state transitions.

### Effect Handlers

```typist
handle { BODY } Effect => +{ op => sub { ... } };
```

Installs scoped effect handlers, executes BODY, and guarantees cleanup even on exception. The `Exn` effect bridges Perl's `die` to the handler system:

```typist
handle { die "oops\n" } Exn => +{ throw => sub ($err) { "recovered" } };
```

### Variadic Functions

```typist
sub log :sig((Str, ...Any) -> Void) ($fmt, @args) { ... }
```

Rest parameter with `...Type` syntax. Arity checking uses minimum args. Default parameters (`$x = expr`) reduce minimum arity via `default_count`.

### Type Narrowing

- `defined($x)` narrows `Maybe[T]` to `T` in the then-block.
- `if ($x)` (truthiness) narrows by removing `Undef`.
- `$x isa Foo` narrows to `Foo`.
- `ref($x) eq 'TYPE'` / `ref($x) ne 'TYPE'` narrows to the corresponding type (with or without parens on `ref`).
- `return unless defined($x)` narrows for the rest of the body (early return).
- Else-blocks receive inverse narrowing.

### Literal Widening

Unannotated `my $var = LITERAL` widens `Literal(v, B)` to `Atom(B)`:

- `my $total = 0` infers as `Int`
- `my $rate = 3.14` infers as `Double`
- `my $name = "hi"` infers as `Str`
- `Bool` base widens to `Int` (0/1 are numbers in Perl)

Expression-level inference is unchanged: `Infer->infer_expr` still returns `Literal(0, 'Bool')`.

### Variable Reassignment

`:sig` annotated variables are checked on reassignment (`$x = expr`). Unannotated variables are not checked.

### Method Calls

All of the following are type-checked:

- `$self->method()` -- same-package instance method.
- `$p->name()` -- cross-package struct accessor.
- `Person->new()` -- class method.
- `Name::derive($p, ...)->greet()` -- chained calls via return type resolution.
- Generic methods -- delegated to `_check_generic_call`.
- Record accessor calls.

Union receivers and untyped receivers are gradual-skipped.

### Return Type Inference

- `handle { BLOCK }` infers from the block's last expression.
- `match` collects arm return types and computes union/LUB.
- Both bypass the `Word + List` call pattern used for normal function inference.

### Cross-File Typeclass Instances

`instance` declarations are extracted, registered (existence only), and tracked per-file by Workspace. Static registration does not validate method completeness (cross-file ordering is non-deterministic); completeness checking is deferred to runtime.

---

## Namespace Model

Typist operates in two distinct worlds. Understanding where each name lives is essential for working with the system.

### The Two Worlds

| World | Content | Resolution |
|-------|---------|------------|
| **Perl** | Subroutine calls, `use`/`import`, `@EXPORT` | Perl's standard namespace rules |
| **Typist** | Type expressions inside `:sig()`, `typedef`, struct field types | Typist's Parser + Registry (string-based, global) |

A type name like `Int` exists in both worlds:

- In `:sig(Int)` — the string token `"Int"` is resolved by the Parser against the Registry. **No import needed.**
- In `typedef Name => 'Int'` — the string `'Int'` is coerced into a type object via `Typist::Type->coerce`. **No import needed.**

### Synthetic Namespaces

Several Typist keywords create namespaces that have no corresponding `.pm` file. These follow a uniform pattern: **`${TypeName}::${operation}`**.

| Keyword | Created namespace | Operations | Perl callable? |
|---------|------------------|------------|---------------|
| `effect Logger => +{...}` | `Logger::` | `Logger::log(...)` | Yes — runtime effect dispatch |
| `typeclass Show => ...` | `Show::` | `Show::show(...)` | Yes — runtime instance dispatch |
| `newtype UserId => ...` | `UserId::` | `UserId::coerce(...)` | Yes — unwrap inner value |
| `struct Person => (...)` | `Person::` | `Person::derive(...)`, `Person::name(...)` | Yes — derive + accessors |
| `datatype Option => (...)` | *(none)* | — | Constructors (`Some`, `None`) go into the defining package |

These are available after the defining code has executed (typically in a `BEGIN` block). If `Shop::Types` defines `effect Logger => ...`, then any code loaded after `use Shop::Types` can call `Logger::log(...)`.

### What `use` Controls

| Statement | What it does |
|-----------|-------------|
| `use Typist` | Enables the type system for this package (attribute handlers, CHECK registration). |
| `use Typist -runtime` | Additionally enables Tie::Scalar monitoring for `:sig()` variables. |
| `use Shop::Types` | (1) Imports constructors via Exporter. (2) Side-effect: registers types in the global Registry, making them available in `:sig()`. (3) Side-effect: creates synthetic namespaces for effects/typeclasses. |

### Dependency Tracking

When reading code, there are two kinds of dependencies to trace:

- **Visible** (via `use`): constructor functions, Exporter `@EXPORT` items.
- **Implicit** (via Registry side-effects): type names in `:sig()`, synthetic namespace operations.

Both are activated by `use`, but only the first kind appears in `@EXPORT`. The second kind is a side-effect of executing `BEGIN` blocks that call `typedef`, `newtype`, `effect`, etc.

### Visibility Check (ImportHint)

The static analyzer tracks type **provenance** (which package defined each type) and **use chains** (which packages the current file imports). When a type name used in `:sig()` was defined in a package that is not reachable through the current file's `use` declarations, an `ImportHint` diagnostic (severity: hint) is emitted.

This is an advisory check, not a hard error — types still resolve via the global Registry regardless of visibility. The diagnostic helps developers maintain explicit import discipline.

```
# ✗ ImportHint: Type 'Amount' (defined in Shop::Types) used but 'Shop::Types' is not imported
package Order;
use v5.40;
sub total :sig((Amount) -> Amount) ($a) { ... }

# ✓ No hint — Shop::Types is explicitly imported
package Order;
use v5.40;
use Shop::Types;
sub total :sig((Amount) -> Amount) ($a) { ... }
```

---

## Design Principles

1. **Static-first** -- errors caught before runtime; runtime enforcement is opt-in.
2. **Immutable types** -- type nodes are value objects; `substitute` returns new nodes.
3. **Flyweight atoms** -- singleton semantics via `%POOL` for primitive types.
4. **Normalized constructors** -- Union/Intersection flatten and deduplicate.
5. **Lazy heavy deps** -- PPI loaded only in CHECK phase, never at runtime.
6. **Dual-mode Registry** -- class methods for singleton (CHECK), instance methods for LSP.
7. **Gradual typing** -- annotation density determines check strictness; `Any` bypasses checks.
8. **Zero runtime cost** -- constructor type validation is opt-in (`-runtime`); structural checks (arity, unknown fields) are always active.
9. **No source filters** -- standard Perl attributes + PPI parsing for static analysis.
10. **Effect handlers** -- `Effect::op(...)`/`handle` provide dynamic-scope effect dispatch at runtime.

---

## Perl Gotchas

### `die` as a List Operator

`die` is a list operator in Perl, so `$x // die "msg", k => v` parses as `$x // die("msg", k => v)`. The `k => v` becomes part of the `die` argument list.

**Fix**: always parenthesize `die` when used with `//` or other low-precedence operators:

```typist
$x // die("msg\n")
```

### PPI `find()` Returns Empty String

`$doc->find('PPI::Token::Word')` returns `''` (empty string) when no results are found, not `undef`.

**Fix**: always normalize the result:

```typist
my $words = $doc->find('PPI::Token::Word') || [];
```

### PPI Quote Content vs String

`$token->content` returns the token including its quote delimiters (e.g., `'hello'`). To get the inner value, use `$token->string` (e.g., `hello`).

### Hashref Disambiguation

A bare `{}` is ambiguous between a block and an anonymous hashref. Always prefix with `+` to force hashref interpretation:

```typist
+{ key => "value" }
```

### PPI Anonymous Sub Signatures

PPI parses anonymous sub signatures as `PPI::Token::Prototype`, not `PPI::Structure::List`. Account for this when traversing anonymous sub parameters.

### `reverse` Precedence

`reverse EXPR .. EXPR` binds incorrectly without parentheses.

**Fix**: always parenthesize:

```typist
reverse(1 .. 10)
```

### `(&@)` Prototype Comma Trap

Functions with `(&@)` prototype (like `handle`, and Perl builtins `map`, `grep`) expect a block followed by a list with no comma separating them. Inserting a comma after the block silently breaks the call:

```typist
# Correct: no comma after block
handle { BLOCK } Logger => +{ ... };

# WRONG: comma after block silently breaks -- list part becomes void-context
handle { BLOCK }, Logger => +{ ... };
```

The same rule applies to `map`, `grep`, `sort`, and any other `(&@)` prototyped function.

### Operator Overload Signature Caveat

Operator overload subs (`use overload`) cannot use Perl subroutine signatures. Use the traditional `@_` unpacking:

```typist
use overload '|' => sub {
    my ($self, $other) = @_;  # NOT sub ($self, $other)
    ...
};
```

---

## Cross-References

- [architecture.md](architecture.md) -- Module dependency graph, lifecycle, registry design, error system.
- [Guide](../guide/index.md) -- All type constructs, subtyping rules, advanced features.
- [static-analysis.md](static-analysis.md) -- Analysis pipeline internals, TypeChecker, EffectChecker, inference.
- [lsp-coverage.md](lsp-coverage.md) -- LSP feature coverage matrix.
