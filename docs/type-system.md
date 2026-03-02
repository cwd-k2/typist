# Typist Type System Reference

This document provides a comprehensive reference for all type constructs, subtyping rules, and advanced features in Typist.

## Table of Contents

- [Primitive Types](#primitive-types)
- [Parameterized Types](#parameterized-types)
- [Union Types](#union-types)
- [Intersection Types](#intersection-types)
- [Function Types](#function-types)
- [Struct Types](#struct-types)
- [Literal Types](#literal-types)
- [Type Aliases](#type-aliases)
- [Nominal Types (Newtype)](#nominal-types-newtype)
- [Algebraic Data Types](#algebraic-data-types)
- [Recursive Types](#recursive-types)
- [Type Variables and Generics](#type-variables-and-generics)
- [Bounded Quantification](#bounded-quantification)
- [Higher-Kinded Types](#higher-kinded-types)
- [Type Classes](#type-classes)
- [Algebraic Effects](#algebraic-effects)
- [Row Polymorphism](#row-polymorphism)
- [Subtyping Rules](#subtyping-rules)
- [Type DSL](#type-dsl)
- [Type Constructors Summary](#type-constructors-summary)

---

## Primitive Types

Typist provides nine primitive (atom) types, organized in a subtype hierarchy:

```
                Any         Top type: every type is a subtype
              / | \ \
           Str Num  | Void   Void: no meaningful return value
            |   |   |
            | Double |       Double: floating-point
            |   |    |
            |  Int   |       Undef: Perl's undef
            |   |    |
            | Bool   |
            |        |
            +--+--+--+
                |
              Never         Bottom type: subtype of everything
```

| Type | Description | Runtime Validator |
|------|-------------|-------------------|
| `Any` | Top type, accepts all values | Always true |
| `Void` | No meaningful value | Always true (phantom) |
| `Never` | Bottom type, no values | Always false |
| `Undef` | Perl's `undef` | `!defined($v)` |
| `Bool` | Boolean values | `$v` is `1`, `0`, or `''` |
| `Int` | Integer values | `looks_like_number($v) && $v == int($v)` |
| `Double` | Floating-point values | `looks_like_number($v)` |
| `Num` | Numeric supertype | `looks_like_number($v)` |
| `Str` | String values | `defined($v) && !ref($v)` |

### Subtype Relations

```
Bool <: Int <: Double <: Num <: Any
Str <: Any
Undef <: Any
Void <: Any
Never <: T (for all T)
```

### Usage

```perl
my $x :sig(Int) = 42;
my $s :sig(Str) = "hello";
my $b :sig(Bool) = 1;
my $d :sig(Double) = 3.14;
my $n :sig(Num) = 3.14;    # Num accepts all numerics
my $u :sig(Undef) = undef;
```

---

## Parameterized Types

Types that take type parameters inside `[...]`:

| Constructor | Kind | Example | Contains |
|-------------|------|---------|----------|
| `ArrayRef[T]` | `* -> *` | `ArrayRef[Int]` | Array ref where all elements satisfy `T` |
| `HashRef[K, V]` | `* -> * -> *` | `HashRef[Str, Int]` | Hash ref with key type `K`, value type `V` |
| `Tuple[T, U, ...]` | `* -> ... -> *` | `Tuple[Int, Str]` | Fixed-length array ref with positional types |
| `Ref[T]` | `* -> *` | `Ref[Int]` | Scalar reference to `T` |
| `Maybe[T]` | `* -> *` | `Maybe[Str]` | Desugars to `T \| Undef` |
| `CodeRef[A -> R]` | `* -> *` | `CodeRef[Int -> Str]` | Desugars to `Func([A], R)` |

The DSL also provides short aliases `Array[T]` and `Hash[K, V]` for `ArrayRef[T]` and `HashRef[K, V]`.

### Subtyping

Parameterized types are **covariant** in all parameters:

```
ArrayRef[Int] <: ArrayRef[Double]    (because Int <: Double)
HashRef[Str, Int] <: HashRef[Str, Num]
```

### Usage

```perl
my $nums :sig(ArrayRef[Int]) = [1, 2, 3];
my $map  :sig(HashRef[Str, Int]) = { a => 1, b => 2 };
my $pair :sig(Tuple[Str, Int]) = ["Alice", 30];
my $opt  :sig(Maybe[Str]) = undef;   # OK: Str | Undef
```

---

## Union Types

`T | U` — a value that belongs to either `T` or `U`.

### Properties

- **Normalized**: nested unions are flattened (`(A|B)|C` = `A|B|C`)
- **Deduplicated**: structurally equal members are collapsed
- **Single-member collapse**: `Union(T)` = `T`

### Subtyping

```
T|U <: S   iff  T <: S  AND  U <: S     (all members must subtype)
S <: T|U   iff  S <: T  OR   S <: U     (any member suffices)
```

### Usage

```perl
my $id :sig(Int | Str) = 42;
$id = "abc";    # OK

typedef Result => 'Str | Undef';
```

---

## Intersection Types

`T & U` — a value that belongs to both `T` and `U`.

### Properties

- **Normalized**: nested intersections are flattened
- **Deduplicated**: structurally equal members are collapsed
- **Single-member collapse**: `Intersection(T)` = `T`

### Subtyping

```
T&U <: S   iff  T <: S  OR   U <: S     (any member suffices)
S <: T&U   iff  S <: T  AND  S <: U     (all members must subtype)
```

### Usage

```perl
typedef ReadWrite => 'Readable & Writable';
```

---

## Function Types

`(A, B) -> R` or `(A, B) -> R ![E]` — function signature with optional effects.

### Syntax

```
(Params) -> Return                    Pure function
(Params) -> Return ![Labels]          Effectful function
<Generics>(Params) -> Return ![E]     Generic effectful function
```

### Subtyping

Function types follow the standard variance rules:

```
Parameters:   Contravariant    (A)->R <: (B)->R iff B <: A
Return type:  Covariant        (A)->R <: (A)->S iff R <: S
Effects:      Covariant        ..!E1 <: ..!E2 iff E1 <: E2
Arity:        Strict           Must match exactly
```

### Usage

```perl
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
sub greet :sig((Str) -> Str ![Console]) ($name) { "Hello, $name!" }
```

---

## Struct Types

`{ key => Type, key? => Type }` — structural record types with optional fields.

### Syntax

```
{ name => Str, age => Int }              All required
{ name => Str, age? => Int }             age is optional
{ host => Str, port => Int, tls? => Bool }
```

### Subtyping (Width Subtyping)

A struct with **more fields** is a subtype of one with **fewer fields**:

```
{ name => Str, age => Int, email => Str }  <:  { name => Str, age => Int }
```

Field types are checked covariantly:

```
{ age => Int }  <:  { age => Num }     (because Int <: Num)
```

Optional fields:
- A required field `k => T` subtypes an optional field `k? => T`
- An optional field `k? => T` does NOT subtype a required field `k => T`

### Usage

```perl
typedef Person => '{ name => Str, age => Int }';
typedef Config => '{ host => Str, port => Int, tls? => Bool }';

my $p :sig(Person) = { name => "Alice", age => 30 };
```

---

## Literal Types

Singleton types for specific values: `42`, `"hello"`, `3.14`.

### Hierarchy

Each literal type has a **base type** that it subtypes:

```
Literal("hello", Str)  <:  Str     <:  Any
Literal(42, Int)       <:  Int     <:  Double  <:  Num  <:  Any
Literal(3.14, Double)  <:  Double  <:  Num     <:  Any
```

### Equality

Two literal types are equal iff both value and base type match:

```
Literal(42, Int)  =  Literal(42, Int)       # Equal
Literal(42, Int)  != Literal(42, Double)    # Different base
Literal(42, Int)  != Literal(43, Int)       # Different value
```

### Static Inference

The static type inferrer produces literal types from source literals:

```perl
42          # Literal(42, Int)
3.14        # Literal(3.14, Double)
"hello"     # Literal("hello", Str)
0, 1        # Literal(0, Bool), Literal(1, Bool)
```

---

## Type Aliases

`typedef Name => Expr` creates a named reference to a type expression.

### Resolution

Aliases are resolved lazily through the Registry. On first access, the alias expression is parsed and the resulting type is cached.

### Cycle Detection

Bare alias cycles (`A -> B -> A` without a type constructor intervening) are detected at resolution time and raise a `CycleError`:

```perl
typedef A => 'B';
typedef B => 'A';   # CycleError: cycle detected
```

Productive recursion (through a type constructor) is allowed:

```perl
typedef IntList => 'Int | ArrayRef[IntList]';   # OK
```

### Usage

```perl
BEGIN {
    typedef Name   => 'Str';
    typedef Price  => 'Int';
    typedef Person => '{ name => Name, age => Int }';
}
```

---

## Nominal Types (Newtype)

`newtype Name => Expr` creates a **nominal** (name-based) type wrapper.

### Key Properties

- `UserId` is NOT a subtype of `Int`, even if defined as `newtype UserId => 'Int'`
- Only `UserId` values satisfy the `UserId` type
- Constructor validates the inner type (boundary enforcement, always active)
- Values are blessed scalar references (`Typist::Newtype::$name`)

### Subtyping

```
UserId <: UserId     # Only nominal identity
UserId </: Int       # Not structural
Int </: UserId       # Not structural
```

### Usage

```perl
BEGIN {
    newtype UserId  => 'Int';
    newtype Email   => 'Str';
}

my $uid = UserId(42);            # Constructs, validates inner type
my $raw = $uid->base;            # Extracts inner value: 42

eval { UserId("not a number") }; # Dies: validation failure
```

---

## Algebraic Data Types

`datatype Name => Tag => '(Types)', ...` creates a tagged union (sum type) with named constructors.

### Definition

```perl
BEGIN {
    datatype Shape =>
        Circle    => '(Int)',
        Rectangle => '(Int, Int)',
        Point     => '';              # No-argument variant
}
```

### Type Node

The `Type::Data` node stores a name and a variant map:

```
Data("Shape", {
    Circle    => [Atom(Int)],
    Rectangle => [Atom(Int), Atom(Int)],
    Point     => [],
})
```

### Nominal Identity

Data types use name-based equality, like newtypes:

```
Shape == Shape     (same data type name)
Shape != Int       (different type)
```

### Constructor Generation

Each variant produces a constructor function in the calling namespace:

```perl
my $c = Circle(5);             # Typist::Data::Shape { _tag => 'Circle', _values => [5] }
my $r = Rectangle(3, 4);      # Typist::Data::Shape { _tag => 'Rectangle', _values => [3, 4] }
my $p = Point();               # Typist::Data::Shape { _tag => 'Point', _values => [] }
```

Constructors perform boundary enforcement:
- Arity check: number of arguments must match variant definition
- Type check: each argument is validated against the declared type via `contains()`

### Type Interface

`Type::Data` implements the standard type interface:

| Method | Behavior |
|--------|----------|
| `contains($val)` | Checks blessed class, tag existence, arity, and element types |
| `free_vars()` | Collects free variables across all variant parameter types |
| `substitute($bindings)` | Returns new Data node with substituted variant types |
| `equals($other)` | Name-based identity (`is_data && same name`) |

### Registration

Data types are registered in the Registry under `datatypes`:

```perl
Registry->register_datatype($name, $data_type);
Registry->lookup_datatype($name);
Registry->lookup_type($name);    # Also resolves datatypes
```

---

## Recursive Types

Self-referential type definitions through productive recursion:

```perl
BEGIN {
    typedef IntList => 'Int | ArrayRef[IntList]';

    typedef Json => 'Str | Int | Num | Bool | Undef
                   | ArrayRef[Json]
                   | HashRef[Str, Json]';
}
```

### How It Works

The `Type::Alias` node resolves lazily. When it encounters itself during resolution, it returns a fresh `Alias` node (self-reference). A depth guard (`$MAX_DEPTH = 50`) prevents infinite recursion in `contains()`.

### Requirement

Recursion must go through a type constructor (`ArrayRef`, `HashRef`, etc.). Bare recursion is detected as a cycle error.

---

## Type Variables and Generics

### Type Variables

Type variables represent unknown types in generic signatures:

```
T, U, V                      Single-character (DSL constants)
T: Num                        With upper bound
F: * -> *                     With kind annotation
```

### Generic Functions

```perl
# Simple generic
sub first :sig(<T>(ArrayRef[T]) -> T) ($arr) {
    $arr->[0];
}

# Multiple type variables
sub pair :sig(<T, U>(T, U) -> Tuple[T, U]) ($a, $b) {
    [$a, $b];
}
```

### Instantiation (Runtime)

At runtime (`-runtime` mode), generic functions use Hindley-Milner style unification:

1. Infer the type of each argument via `Inference->infer_value()`
2. Unify inferred types with parameter types to build a binding map
3. Apply bindings to the return type

### Static Behavior

The static type checker performs full type checking of generic function call sites via `Static::Unify`:

1. Infer argument types at the call site
2. Structurally unify formal parameter types against actual argument types to extract type-variable bindings (with LUB widening for repeated variables)
3. Check bounded quantification constraints against the inferred bindings
4. Substitute bindings into formal types and verify concrete subtype relations

This catches type errors, bound violations, and structural mismatches at compile time without requiring explicit type application.

---

## Bounded Quantification

Type variables can be bounded above by a type:

```perl
# T must be a subtype of Num
sub max_of :sig(<T: Num>(T, T) -> T) ($a, $b) {
    $a > $b ? $a : $b;
}
```

### Checking

- **Runtime**: `Subtype->is_subtype($actual_type, $bound_type)` for each instantiated generic
- **Static (TypeChecker)**: after unification, checks `is_subtype(bindings{T}, bound)` for each bounded variable
- **Static (Checker)**: validates that bound expressions are well-formed and parseable

### Multiple Bounds

Multiple bounds can be combined with `+`:

```perl
sub sorted_show :sig(<T: Ord + Show>(ArrayRef[T]) -> Str) ($arr) { ... }
```

This checks both typeclass constraints at instantiation time.

---

## Higher-Kinded Types

### Kind System

```
Kind::Star    *            Concrete types (Int, Str, ArrayRef[Int])
Kind::Row     Row          Effect rows
Kind::Arrow   k1 -> k2    Type constructors (ArrayRef :: * -> *)
```

### Built-in Constructor Kinds

```
ArrayRef  :: * -> *
HashRef   :: * -> * -> *
Ref       :: * -> *
Maybe     :: * -> *
```

### Usage in Type Classes

```perl
use Typist::DSL qw(TVar);

BEGIN {
    typeclass Functor => TVar('F', kind => '* -> *'), +{
        fmap => 'CodeRef[CodeRef[A -> B], F[A] -> F[B]]',
    };
}
```

### Type Variable Application

Type constructor variables can be applied to type arguments using bracket syntax:

```perl
# F is a type constructor variable (* -> *)
# F[A] applies F to the concrete type A
F[A] -> F[B]    # e.g., ArrayRef[Int] -> ArrayRef[Str]
```

### Kind Checking

The `KindChecker` validates that type applications are kind-correct:

```
ArrayRef[Int]      OK:  (* -> *) applied to *  =  *
ArrayRef[Int, Str] Error: too many arguments for * -> *
```

Kind checking is performed during the Checker's structural validation pass for all registered functions.

---

## Type Classes

### Definition

```perl
BEGIN {
    typeclass Show => T, +{
        show => '(T) -> Str',
    };
}
```

### Multi-Parameter Type Classes

Type classes can have multiple type parameters for expressing relations between types:

```perl
BEGIN {
    typeclass Convertible => 'T, U', +{
        convert => '(T) -> U',
    };
}
```

Multi-parameter instances specify comma-separated types:

```perl
BEGIN {
    instance Convertible => 'Int, Str', +{
        convert => sub ($x) { "$x" },
    };
}
```

### Instances

```perl
BEGIN {
    instance Show => Int, +{
        show => sub ($x) { "$x" },
    };

    instance Show => Str, +{
        show => sub ($x) { qq{"$x"} },
    };
}
```

### Dispatch

Type class methods are dispatched at runtime based on inferred argument types:

```perl
Show::show(42);       # Dispatches to Int instance → "42"
Show::show("hello");  # Dispatches to Str instance → "\"hello\""
```

Dispatch path:
1. `Inference->infer_value($args[0])` — infer the runtime type
2. `Registry->resolve_instance(class, type)` — find matching instance
3. Call instance method coderef

For multi-parameter type classes, dispatch infers types from the first N arguments (where N is the class arity).

### Instance Resolution

Resolution checks (in order):
1. Exact match by `equals` on the type
2. Constructor match for parameterized types (`ArrayRef` matches any `ArrayRef[T]`)
3. Subtype inclusion (`Int` matches a `Num` instance if no `Int` instance exists)

For multi-parameter resolution, each argument type is matched against the corresponding position in the comma-separated `type_expr`.

### Superclass Hierarchy

```perl
BEGIN {
    typeclass Eq => T, +{
        eq_ => '(T, T) -> Bool',
    };

    typeclass Ord => 'T: Eq', +{
        compare => '(T, T) -> Int',
    };

    # Registering Ord for Int requires Eq for Int to exist
    instance Eq => Int, +{ eq_ => sub ($a, $b) { $a == $b ? 1 : 0 } };
    instance Ord => Int, +{ compare => sub ($a, $b) { $a <=> $b } };
}
```

### Current Limitations

- No default method implementations
- No functional dependencies
- Method signatures stored as strings, not type-checked against implementations
- Dispatch based on first argument (single-param) or first N arguments (multi-param)

---

## Algebraic Effects

### Effect Definition

```perl
BEGIN {
    effect Console => +{
        readLine  => 'CodeRef[-> Str]',
        writeLine => 'CodeRef[Str -> Void]',
    };

    effect DB => +{
        query => 'CodeRef[Str -> Any]',
    };
}
```

### Effect Annotation

Functions declare their effects with `![...]`:

```perl
sub greet :sig((Str) -> Str ![Console]) ($name) { ... }
sub fetch :sig((Str) -> Any ![DB, Console]) ($query) { ... }
```

### Effect Checking Rules

```
Rule                                        Result
─────────────────────────────────────────   ──────────────
Pure caller calls pure callee               OK
Effectful caller calls callee with subset   OK
Effectful caller calls callee with extras   EffectMismatch
Pure caller calls effectful callee          EffectMismatch
Any caller calls unannotated callee         EffectMismatch (warning)
```

### Effect Superset Rule

A caller with `[A, B, C]` can call a callee with `[A]` — the caller's effects are a superset. The reverse is an error.

### Unannotated Functions

Unannotated functions are treated as `[*]` — they may perform any effect. Calling an unannotated function from an annotated function triggers an `EffectMismatch` warning.

### Declare for Builtins

Perl builtins (say, print, die, etc.) receive default annotations from the Prelude (see `Typist::Prelude`). Use `declare` to override with custom annotations:

```perl
declare say    => '(Str) -> Void ![Console]';
declare die    => '(Any) -> Never ![Abort]';
declare length => '(Str) -> Int';              # Pure
```

### Effect Operations (Direct Calls)

Effect definitions auto-install qualified subs for each operation. These dispatch to the nearest handler on the runtime stack:

```perl
# Call effect operations directly as qualified subs
my $line = Console::readLine();

# Provide a handler in a dynamic scope
handle {
    my $input = Console::readLine();
    Console::writeLine("You said: $input");
} Console => +{
    readLine  => sub { "hello" },
    writeLine => sub ($msg) { print $msg },
};
```

### Handler Stack

`Typist::Handler` maintains a LIFO stack of effect handlers. `handle` pushes handlers, executes the body, and pops handlers (even on exception). Effect operation calls search the stack from top to bottom for a matching handler.

```
handle { ... } Console => +{...}, DB => +{...};
  → push Console handler
  → push DB handler
  → execute body
  → pop DB handler
  → pop Console handler
```

Inner handlers shadow outer ones for the same effect, enabling nested scoping.

### Prelude Effects

The `Typist::Prelude` pre-registers `IO` and `Exn` effect labels with default annotations for common builtins (say, print, warn, die, open, close). These coexist with user-defined effects and can be overridden via `declare`.

---

## Row Polymorphism

### Row Types

A row is an ordered set of effect labels with an optional tail variable:

```
Row(Console)              Closed row: exactly Console
Row(Console, State)       Closed row: exactly Console + State
Row(Console, r)           Open row: Console + whatever r provides
```

### Row Variables

Declared in the generic list with `r: Row`:

```perl
sub with_log :sig(<r: Row>(Str) -> Str ![Log, r]) ($msg) {
    $msg;
}
```

This means: the function performs `Log` plus whatever additional effects `r` provides. Callers determine `r` at the call site.

### Row Subtyping

```
Row(A, B, C) <: Row(A, B)     More labels = subtype (more specific)
Row(A) <: Row(A)               Identity
```

### Row Unification (Runtime)

Row unification follows Remy-style semantics:

Given `Row(A, B, r1)` unified with `Row(B, C, r2)`:
- Excess of left in right: `{A}` → `r2 := Row(A, r1)`
- Excess of right in left: `{C}` → `r1 := Row(C, r2)`

### Static Behavior

When either the caller or callee has an open row (row variable), the static effect checker **skips** the inclusion check. Open rows require runtime unification, which is not performed statically.

---

## Subtyping Rules

Complete reference of all subtyping rules implemented in `Typist::Subtype`:

```
#   Rule                  Condition                           Result
──  ────────────────────  ──────────────────────────────────  ──────
1   Identity              sub.equals(super)                   true
2   Top                   super = Any                         true
3   Bottom                sub = Never                         true
4   Void                  sub = Void, super != Any            false
5   Alias                 resolve both, then re-check         recurse
6   Union-sub             T|U <: S                            T<:S ∧ U<:S
7   Union-super           S <: T|U                            S<:T ∨ S<:U
8   Intersection-sub      T&U <: S                            T<:S ∨ U<:S
9   Intersection-super    S <: T&U                            S<:T ∧ S<:U
10  Newtype               name equality                       nominal
11  Data                  name equality                       nominal
12  Literal-Literal       value= ∧ base<:base                 structural
13  Literal-Atom          literal.base <: atom                 promotion
14  Atom-Atom             ancestor chain via %PARENT           hierarchy (Bool<:Int<:Double<:Num<:Any)
15  Param                 same constructor ∧ covariant params  structural
16  Func-params           contravariant                        reversed
17  Func-return           covariant                            normal
18  Func-effects          covariant                            normal
19  Func-arity            must match exactly                   strict
20  Struct-required       all super fields present in sub      width
21  Struct-optional       required subtypes optional           width
22  Struct-field          covariant field types                 depth
23  Eff                   delegate to Row                      structural
24  Row                   label set inclusion                  set theory
25  Default               anything else                        false
```

---

## Type DSL

`Typist::DSL` provides convenient constants and constructors for building type expressions programmatically:

### Atom Constants

```perl
use Typist qw(Int Str Double Num Bool Any Void Never Undef);

Int, Str, Double, Num, Bool, Any, Void, Never, Undef
```

These are `use constant` singletons backed by `Typist::Type::Atom` flyweight pool entries. Imported via `use Typist qw(...)` selective import.

### Type Variable Constants

```perl
use Typist qw(T U V A B K);     # Single-character type variables

# For advanced usage (multi-char vars, kind annotations):
use Typist::DSL qw(TVar);
TVar('Elem')                     # Multi-character type variable
TVar('F', kind => '* -> *')     # With kind annotation
```

### Parametric Constructors

```perl
use Typist qw(ArrayRef Array HashRef Hash Tuple Maybe Record);

ArrayRef(Int)                    # ArrayRef[Int]
Array(Int)                       # ArrayRef[Int]  (alias)
HashRef(Str, Int)                # HashRef[Str, Int]
Hash(Str, Int)                   # HashRef[Str, Int]  (alias)
Tuple(Int, Str, Bool)            # Tuple[Int, Str, Bool]
Maybe(Str)                       # Str | Undef
Record(name => Str, age => Int)  # { name => Str, age => Int }
```

`Func`, `Row`, `Eff`, `TVar`, `Alias` are internal constructors available via `use Typist::DSL qw(:internal)`.

### Operator Overloads

```perl
Int | Str          # Union: Int | Str
Readable & Writable # Intersection: Readable & Writable
"$type"            # Stringify: to_string()
```

### Type Coercion

`Typist::Type->coerce($expr)` accepts both Type objects and strings:

```perl
Typist::Type->coerce('Int')           # Atom(Int)
Typist::Type->coerce(Int)             # Atom(Int) (DSL constant, passthrough)
Typist::Type->coerce('ArrayRef[Str]') # Param(ArrayRef, Atom(Str))
```

### Importing DSL Symbols

The recommended way is selective import via `use Typist qw(...)`:

```perl
use Typist qw(Int Str Record optional);       # Import specific names

BEGIN {
    typedef Name   => Str;                     # DSL form
    typedef Person => Record(name => Str);     # DSL form
    typedef Config => '{ host => Str }';       # String form (always works)
}
```

For advanced usage, `Typist::DSL` provides export tags:

```perl
use Typist::DSL qw(:all);       # All symbols (types + vars + internal)
use Typist::DSL qw(:vars);      # T, U, V, A, B, K
use Typist::DSL qw(:internal);  # TVar, Alias, Row, Eff, Func
```

---

## Type Constructors Summary

| Constructor | Module | Kind | Syntax |
|-------------|--------|------|--------|
| `Atom` | `Type::Atom` | `*` | `Int`, `Str`, `Double`, `Num`, `Bool`, `Any`, `Void`, `Never`, `Undef` |
| `Param` | `Type::Param` | `* -> ... -> *` | `ArrayRef[T]` (alias: `Array[T]`), `HashRef[K, V]` (alias: `Hash[K, V]`), `Tuple[T, U]` |
| `Union` | `Type::Union` | `*` | `T \| U` |
| `Intersection` | `Type::Intersection` | `*` | `T & U` |
| `Func` | `Type::Func` | `*` | `(A, B) -> R`, `(A) -> R ![E]` |
| `Struct` | `Type::Struct` | `*` | `{ k => T, k? => T }` |
| `Literal` | `Type::Literal` | `*` | `42`, `"hello"`, `3.14` |
| `Alias` | `Type::Alias` | `*` | `typedef Name => Expr` |
| `Newtype` | `Type::Newtype` | `*` | `newtype Name => Expr` |
| `Data` | `Type::Data` | `*` | `datatype Name => Tag => '(T)', ...` |
| `Var` | `Type::Var` | `*` or `k` | `T`, `T: Num`, `F: * -> *` |
| `Row` | `Type::Row` | `Row` | `Row(A, B, r)` |
| `Eff` | `Type::Eff` | `Row` | `[Row]`, `![Console, Log]` |
| `Fold` | `Type::Fold` | -- | `map_type` (bottom-up), `walk` (top-down) |
