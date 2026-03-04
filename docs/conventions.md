# Conventions

> Canonical reference for Typist coding conventions, design patterns, and known Perl gotchas.
> For architecture overview, see [architecture.md](architecture.md).
> For type system reference, see [type-system.md](type-system.md).
> For static analysis internals, see [static-analysis.md](static-analysis.md).

## Table of Contents

- [Language and Module Conventions](#language-and-module-conventions)
- [Type System Conventions](#type-system-conventions)
- [Static-First Design](#static-first-design)
- [Syntax Conventions](#syntax-conventions)
- [Feature Reference](#feature-reference)
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
  - Immutable updates: `$obj->with(field => val)`
  - `optional(Type)` marks fields that can be omitted.
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

`use Typist;` enables static-only analysis. No runtime overhead: original subs execute directly with no tie, no wrappers.

### Runtime Mode

`use Typist -runtime;` (or `TYPIST_RUNTIME=1`) additionally enables `Tie::Scalar` variable monitoring on `:sig()` annotated variables.

### Boundary Enforcement (Always Active)

Constructor boundary validation is always on, regardless of `-runtime`:

- **newtype**: `$inner->contains($value)` validates the inner type. `$val->base` extracts the inner value.
- **datatype**: argument count + `$type->contains($arg)` per argument.
- **struct**: unknown/missing field checks + per-field type validation.
- **Effect dispatch**: `Effect::op(@args)` dispatches to the nearest handler on the runtime stack.

### CHECK Phase

The CHECK phase runs both structural checks (`Checker`) and full static analysis (`Analyzer` with `TypeChecker` + `EffectChecker`) per loaded package. Diagnostics surface as `warn` to STDERR, which perlnavigator picks up.

Suppress with `TYPIST_CHECK_QUIET=1` when using typist-lsp to avoid duplicate diagnostics.

### Gradual Typing

Annotation density determines check strictness:

- **Fully annotated** -- all checks enforced.
- **Partially annotated** (some `:sig()`, no `:Eff`) -- pure effect assumed, return type unknown if no `:Returns`.
- **Completely unannotated** -- `(Any...) -> Any`, type checks skip, effect treated as pure (no constraint).

```
Mechanism          | use Typist (default) | use Typist -runtime
-------------------|----------------------|---------------------
Static Analysis    | ON                   | ON
CHECK diagnostics  | ON                   | ON
Constructor checks | ON                   | ON
Effect dispatch    | ON                   | ON
Tie::Scalar        | OFF                  | ON
```

---

## Syntax Conventions

### Hashref Literals

Always use `+{}` to disambiguate from blocks:

```perl
my $config = +{ host => "localhost", port => 8080 };
```

### String Syntax for Signatures

Typeclass and effect definitions use string syntax for method/operation signatures, consistent with `:sig()` annotations:

```perl
show => '(T) -> Str'
```

The Extractor only captures `PPI::Token::Quote`, so DSL `Func(...)` does not work for static analysis.

### Selective DSL Export

The recommended import style names what you use:

```perl
use Typist qw(Int Str Record optional);
```

Bare `use Typist` exports only core functions (typedef, newtype, struct, etc.). DSL names are uppercase-starting or `optional`. `Typist::DSL->export_map` provides the full name-to-coderef mapping.

### Unified `:sig()` Annotation

```perl
sub add :sig(<T: Num>(T, T) -> T ! Console) ($a, $b) { ... }
```

- Generics in `<>`.
- Arrow `->` separates parameters from return type.
- `!` introduces the effect row.

### LSP Coverage Rule

When adding or modifying static analysis features, update `docs/lsp-coverage.md`. New analysis outputs must have corresponding LSP entries (or an explicit "N/A" with rationale).

---

## Feature Reference

### Algebraic Data Types (ADT)

```perl
datatype Shape => Circle => '(Int)', Rectangle => '(Int, Int)';
```

Constructors are installed into the caller's namespace. Parameterized ADTs:

```perl
datatype 'Option[T]' => Some => '(T)', None => '()';
```

Type params are promoted from aliases to Var objects. Subtyping is covariant in type arguments.

### GADT

```perl
datatype 'Expr[A]' => IntLit => '(Int) -> Expr[Int]', BoolLit => '(Bool) -> Expr[Bool]';
```

Constructors with `->` specify per-constructor return types. Provides `is_gadt` predicate and `constructor_return_type($tag)` accessor.

### Enum

```perl
enum Color => qw(Red Green Blue);
```

Sugar for `datatype` with all zero-argument variants.

### Pattern Matching

```perl
match $value, Tag => sub (...) { ... }, _ => sub { ... };
```

Dispatches on `_tag`, splats `_values` into handlers. `_` is the optional fallback arm. Emits exhaustiveness warnings for registered ADTs when arms are incomplete and no fallback is given.

### Effects

```perl
effect Console => +{ writeLine => '(Str) -> Void' };
```

Operations are auto-installed as qualified subs (`Console::writeLine(@args)`), dispatching to the nearest handler on the runtime stack.

### Effect Protocols

```perl
effect DB => qw/Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', '* -> Connected'),
    query      => protocol('(Str) -> Str',  'Authed -> Authed'),
    disconnect => protocol('() -> Void',    'Authed -> *'),
};
```

`*` is the ground state (protocol inactive). Only active states appear in the states list. A function that begins a protocol session transitions from `*`:

```perl
sub start_session :sig(() -> Void ![DB<* -> Connected>]) ($self) { ... }
```

Mid-protocol functions may use any valid active state as `From`:

```perl
sub run_query :sig((Str) -> Str ![DB<Authed>]) ($self, $q) { ... }
```

Annotation: `![DB<* -> Authed>]` declares start/end states. `![DB<Authed>]` is invariant. `![DB]` defaults to `* -> *` (full session cycle). ProtocolChecker traces operation sequences and verifies state transitions.

### Effect Handlers

```perl
handle { BODY } Effect => +{ op => sub { ... } };
```

Installs scoped effect handlers, executes BODY, and guarantees cleanup even on exception.

### Variadic Functions

```perl
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
- `$p->with(...)->greet()` -- chained calls via return type resolution.
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

## Design Principles

1. **Static-first** -- errors caught before runtime; runtime enforcement is opt-in.
2. **Immutable types** -- type nodes are value objects; `substitute` returns new nodes.
3. **Flyweight atoms** -- singleton semantics via `%POOL` for primitive types.
4. **Normalized constructors** -- Union/Intersection flatten and deduplicate.
5. **Lazy heavy deps** -- PPI loaded only in CHECK phase, never at runtime.
6. **Dual-mode Registry** -- class methods for singleton (CHECK), instance methods for LSP.
7. **Gradual typing** -- annotation density determines check strictness; `Any` bypasses checks.
8. **Boundary enforcement** -- newtype and datatype constructors always validate, independent of mode.
9. **No source filters** -- standard Perl attributes + PPI parsing for static analysis.
10. **Effect handlers** -- `Effect::op(...)`/`handle` provide dynamic-scope effect dispatch at runtime.

---

## Perl Gotchas

### `die` as a List Operator

`die` is a list operator in Perl, so `$x // die "msg", k => v` parses as `$x // die("msg", k => v)`. The `k => v` becomes part of the `die` argument list.

**Fix**: always parenthesize `die` when used with `//` or other low-precedence operators:

```perl
$x // die("msg\n")
```

### PPI `find()` Returns Empty String

`$doc->find('PPI::Token::Word')` returns `''` (empty string) when no results are found, not `undef`.

**Fix**: always normalize the result:

```perl
my $words = $doc->find('PPI::Token::Word') || [];
```

### PPI Quote Content vs String

`$token->content` returns the token including its quote delimiters (e.g., `'hello'`). To get the inner value, use `$token->string` (e.g., `hello`).

### Hashref Disambiguation

A bare `{}` is ambiguous between a block and an anonymous hashref. Always prefix with `+` to force hashref interpretation:

```perl
+{ key => "value" }
```

### PPI Anonymous Sub Signatures

PPI parses anonymous sub signatures as `PPI::Token::Prototype`, not `PPI::Structure::List`. Account for this when traversing anonymous sub parameters.

### `reverse` Precedence

`reverse EXPR .. EXPR` binds incorrectly without parentheses.

**Fix**: always parenthesize:

```perl
reverse(1 .. 10)
```

### `(&@)` Prototype Comma Trap

Functions with `(&@)` prototype (like `handle`, and Perl builtins `map`, `grep`) expect a block followed by a list with no comma separating them. Inserting a comma after the block silently breaks the call:

```perl
# Correct: no comma after block
handle { BLOCK } Logger => +{ ... };

# WRONG: comma after block silently breaks -- list part becomes void-context
handle { BLOCK }, Logger => +{ ... };
```

The same rule applies to `map`, `grep`, `sort`, and any other `(&@)` prototyped function.

### Operator Overload Signature Caveat

Operator overload subs (`use overload`) cannot use Perl subroutine signatures. Use the traditional `@_` unpacking:

```perl
use overload '|' => sub {
    my ($self, $other) = @_;  # NOT sub ($self, $other)
    ...
};
```

---

## Cross-References

- [architecture.md](architecture.md) -- Module dependency graph, lifecycle, registry design, error system.
- [type-system.md](type-system.md) -- All type constructs, subtyping rules, advanced features.
- [static-analysis.md](static-analysis.md) -- Analysis pipeline internals, TypeChecker, EffectChecker, inference.
- [lsp-coverage.md](lsp-coverage.md) -- LSP feature coverage matrix.
