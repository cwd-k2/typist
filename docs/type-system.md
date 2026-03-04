# Typist Type System Reference

This document provides a comprehensive reference for all type constructs, subtyping rules, and advanced features in Typist.

> For static analysis implementation details, see [static-analysis.md](static-analysis.md).
> For architecture overview, see [architecture.md](architecture.md).

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
- [Nominal Structs](#nominal-structs)
- [Recursive Types](#recursive-types)
- [Type Variables and Generics](#type-variables-and-generics)
- [Bounded Quantification](#bounded-quantification)
- [Higher-Kinded Types](#higher-kinded-types)
- [Type Classes](#type-classes)
- [Algebraic Effects](#algebraic-effects)
- [Row Polymorphism](#row-polymorphism)
- [Subtyping Rules](#subtyping-rules)
- [Type DSL](#type-dsl)
- [Gradual Typing](#gradual-typing)
- [Type Narrowing](#type-narrowing)
- [Builtin Prelude](#builtin-prelude)
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

## Nominal Structs

`struct Name => (field => Type, ...)` creates a **nominal**, immutable, blessed record type. Unlike structural records, structs impose a name-based identity barrier and support generic parameterization.

### Basic Definition

```perl
BEGIN {
    struct Point => (x => Int, y => Int);
    struct Config => (host => Str, port => Int, debug => optional(Bool));
}

my $p = Point(x => 1, y => 2);
say $p->x;                      # 1
my $q = $p->with(x => 10);      # Point(x => 10, y => 2) — immutable update
```

### Generic Structs

Structs can be parameterized over type variables, following the same pattern as `datatype`:

```perl
BEGIN {
    struct 'Pair[T, U]' => (fst => T, snd => U);
    struct 'Box[T]'     => (val => T);
}

my $p = Pair(fst => 42, snd => "hi");   # Pair[Int, Str]
say $p->fst;                             # 42 (inferred as Int)

my $b = Box(val => 3.14);               # Box[Double]
```

**Syntax note**: generic names must be quoted (`'Pair[T, U]'`) because `[` would break bareword parsing in Perl.

**Type parameter binding**: at construction time, field values are type-inferred and bound to type variables. The `_type_args` are recorded on the instance and preserved through `with()`.

### Subtyping

```
Point <: Point                       # Nominal identity
Point </: { x => Int, y => Int }     # Nominal barrier (but reversed holds)
{ x => Int, y => Int } </: Point     # Record is never a subtype of Struct

Pair[Int, Str] <: Pair[Int, Str]     # type_args match
Pair[Int, Str] </: Pair[Int, Int]    # type_args differ
Pair[Bool, Str] <: Pair[Int, Str]    # Covariant (Bool <: Int)
```

Generic struct subtyping is covariant: `Box[Bool] <: Box[Int]` because `Bool <: Int`.

### Static Inference

The static inferrer handles generic struct constructors via named-argument binding:

1. Extract `key => value` pairs from the PPI call node
2. Infer each value type and collect bindings against the formal Var-typed fields
3. Widen literal bindings (`Literal(42, Int)` → `Int`)
4. Substitute bindings and produce a concrete `Struct[T1, T2]` type

Accessor inference on generic structs substitutes `type_params → type_args`:

```
$p : Pair[Int, Str]
$p->fst : Int       # Var(T) substituted with Int
$p->snd : Str       # Var(U) substituted with Str
```

### Type Interface

| Method | Behavior |
|--------|----------|
| `type_params` | Returns bound parameter names (`('T', 'U')`) |
| `type_args` | Returns concrete type arguments (`(Int, Str)`) |
| `instantiate(@args)` | Creates a copy with concrete type_args |
| `substitute($bindings)` | Substitutes in both record and type_args |
| `contains($val)` | Checks blessed class, substitutes type_args for field validation |

### Future: Bounded Generic Structs

Generic struct parameters could carry bounded quantification constraints:

```perl
# Not yet implemented — proposed syntax
struct 'SortedPair[T: Ord]' => (lo => T, hi => T);
struct 'Cache[K: Hashable, V]' => (store => HashRef[K, V]);
```

This would require extending `_struct` to parse bound expressions from the type parameter specification (e.g., `T: Ord`) and register them as `generics` with `bound_expr`. The static checker already supports bounded quantification in `_check_generic_call`, so the validation machinery is in place — only the declaration-side parsing needs extension.

Implementation sketch:
1. Parse `'SortedPair[T: Ord]'` → type_params `['T']`, bounds `{T => 'Ord'}`
2. In Registration, emit `generics => [{name => 'T', bound_expr => 'Ord'}]`
3. TypeChecker's existing step 5 (bounded quantification check) handles the rest
4. Runtime constructor validates `Subtype->is_subtype($inferred, $bound)` per field

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

### Typeclass Constraints vs. Type Bounds

The `T: X` syntax is overloaded — the parser (`Attribute->parse_generic_decl`) disambiguates by consulting the Registry:

| Syntax | Resolution | Check |
|--------|-----------|-------|
| `T: Num` | `Num` is not a registered typeclass → **type bound** | `is_subtype(actual, Num)` |
| `T: Show` | `Show` is a registered typeclass → **typeclass constraint** | `resolve_instance("Show", actual)` |
| `T: Show + Eq` | All parts are typeclasses → **multiple tc constraints** | Each checked independently |
| `T: Num + Show` | `Num` is not a typeclass → falls back to **type bound** on `"Num + Show"` | (bound parse) |

**Pipeline step**: bounded quantification is step 5 in `_check_generic_call`; typeclass constraints are step 5.5, evaluated immediately after.

### Multiple Bounds

Multiple typeclass constraints can be combined with `+`:

```perl
sub sorted_show :sig(<T: Ord + Show>(ArrayRef[T]) -> Str) ($arr) { ... }
```

This checks both typeclass constraints at instantiation time. See [Static Typeclass Constraint Checking](#static-typeclass-constraint-checking) for details.

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

### Static Typeclass Constraint Checking

When a generic function is annotated with typeclass constraints (e.g., `<T: Show>`), the static TypeChecker verifies that the inferred type argument has a registered instance:

```perl
typeclass Show => (T => +{ show => '(T) -> Str' });
instance Show => 'Int', +{ show => sub ($x) { "$x" } };

sub show_it :sig(<T: Show>(T) -> Str) ($x) { show($x) }

show_it(42);       # OK — Show instance exists for Int
show_it("hello");  # TypeMismatch: no instance of Show for "hello"
```

Multiple constraints are checked independently:

```perl
sub display_eq :sig(<T: Show + Eq>(T, T) -> Str) ($a, $b) { ... }
# Checks both Show and Eq instances for the inferred type
```

**Pipeline**: after unification binds `T` to a concrete type (step 4), the checker iterates over `tc_constraints` and calls `Registry->resolve_instance($tc_name, $actual)`. Missing instances produce a `TypeMismatch` diagnostic.

**Distinction from bounded quantification**: `T: Num` (bound) checks `is_subtype(actual, Num)`. `T: Show` (typeclass) checks `resolve_instance("Show", actual)`. The parser distinguishes these by consulting the Registry for known typeclass names.

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
Any caller calls unannotated callee         OK (pure)
```

### Effect Superset Rule

A caller with `[A, B, C]` can call a callee with `[A]` — the caller's effects are a superset. The reverse is an error.

### Unannotated Functions

Unannotated functions are treated as pure (no effects). This follows the gradual typing principle: no annotation means no constraint. Calling an unannotated function from any caller produces no effect diagnostic.

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

## Gradual Typing

Typist implements gradual typing: the density of type annotations determines how strictly a program is checked. Code with full annotations receives rigorous verification; code with no annotations passes through unconstrained. This allows incremental adoption -- annotate what matters, leave the rest alone.

### Annotation Levels

```
Level                    Signature                          Behavior
─────────────────────    ──────────────────────────────     ──────────────────────────────────
Fully annotated          :sig((Str) -> Int ![Console])     All checks enforced: params, return,
                                                            arity, effects
Partial (return)         :sig((Str) -> Any)                Param types checked; return type
                                                            unknown (Any), skipped
Partial (effects)        :sig((Str) -> Int)                Types checked; no :Eff annotation
                                                            means treated as pure (no constraint)
Unannotated              sub foo ($x) { ... }              Signature is (Any...) -> Any;
                                                            type checks skip; effect is pure
```

The governing principle: **no annotation means no constraint**. Types default to `Any` (compatible with everything), and effects default to pure (no effects declared). Both directions are permissive -- `Any` satisfies any expected type, and any type satisfies an `Any` expectation.

### The Any Guard

Every check method in the static analyzer includes an `Any` guard that short-circuits when either the inferred or declared type is `Any`:

```perl
next if $inferred->is_atom && $inferred->name eq 'Any';
```

This guard appears in variable initializer checks, assignment checks, call-site argument checks, return type checks, method call checks, and generic instantiation checks. It prevents false positives when one side of a comparison is unknown.

### How Gradual Typing Interacts with Analysis

The type environment distinguishes three states for function names:

```
State                         Meaning                        Type Check Behavior
───────────────────────────   ────────────────────────────   ──────────────────────────
env.functions{name} defined   Return type is known           Use the return type
env.known{name} exists        Partial annotation (no return) Return type is undef; skip check
Neither entry exists          Completely unannotated          Return type is Any; gradual bypass
```

For the effect checker, the same principle applies:

- **Unannotated caller**: the entire function is skipped (no effect checking performed).
- **Unannotated callee**: treated as pure. Calling an unannotated function from an annotated caller produces no `EffectMismatch`.
- **Annotated caller with annotated callee**: full label-inclusion check (callee labels must be a subset of caller labels).

This design ensures that adding annotations to one function never causes errors in unrelated unannotated code.

For the protocol checker, the same gradual principle applies: the handle-driven pass (Pass 2) traces unannotated functions at `* -> *`, but relaxes the handle body end-state check. This allows partial protocol use (e.g. peek/invariant operations) in unannotated handler functions without false `ProtocolMismatch` diagnostics. Annotated functions with explicit `![Effect<* -> *>]` retain the strict check.

### Usage

```perl
# Fully annotated -- all checks active
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }

# Partial -- param types checked, return inferred but not validated
sub greet :sig((Str) -> Any) ($name) { "Hello, $name" }

# Unannotated -- no type errors, no effect errors, acts as (Any...) -> Any
sub helper ($x) { do_something($x) }
```

---

## Type Narrowing

Within control-flow guards, the static analyzer narrows variable types to more specific types based on the condition. This enables precise checking inside branches without requiring explicit casts or additional annotations.

### Narrowing Rules

Five rules are applied in order of specificity. The first matching rule wins:

#### 1. `defined()` Narrowing

`defined($x)` narrows `Maybe[T]` (i.e., `T | Undef`) to `T` by removing `Undef` from the union.

```perl
my $x :sig(Str | Undef) = get_value();
if (defined($x)) {
    # $x is Str here -- Undef removed
    process($x);
}
```

In the else-block, the type narrows to `Undef` only.

#### 2. `isa` Narrowing

`$x isa Foo` narrows the variable to `Foo` in the then-block.

```perl
if ($x isa Person) {
    # $x is Person here
    say $x->name;
}
```

For Union types in the else-block, `isa` applies inverse narrowing: the matched type is subtracted from the union members.

#### 3. `ref()` Narrowing

`ref($x) eq 'TYPE'` narrows based on a mapping from Perl's `ref()` return strings to Typist types:

```
ref() String    Narrowed Type
────────────    ─────────────
HASH            HashRef[Any]
ARRAY           ArrayRef[Any]
SCALAR          Ref[Any]
CODE            Ref[Any]
REF             Ref[Any]
Regexp          Ref[Any]
GLOB            Ref[Any]
IO              Ref[Any]
VSTRING         Str
```

Both forms `ref($x)` and `ref $x` are recognized. Blessed class names are resolved through the registry. The `ne` operator flips the polarity (narrows in the else-block instead).

```perl
if (ref($data) eq 'HASH') {
    # $data is HashRef[Any] here
}
```

Variable comparison is also supported: `ref($x) eq $type` resolves `$type` when it holds a `Literal(String)` value.

#### 4. Truthiness Narrowing

A bare variable in a condition (`if ($x)`) narrows by removing `Undef` from the type, similar to `defined()` but with lower priority.

```perl
my $x :sig(Str | Undef) = get_value();
if ($x) {
    # $x is Str here -- Undef removed by truthiness
}
```

#### 5. Early Return Narrowing

`return unless defined($x)` narrows `$x` for the remainder of the enclosing function body. The analyzer scans preceding siblings of the current statement for this pattern.

```perl
sub process :sig((Str | Undef) -> Str) ($x) {
    return unless defined($x);
    # $x is Str from this point forward
    uc($x);
}
```

### Inverse Narrowing in Else-Blocks

For `if/else` structures, the else-block receives the inverse of the narrowing applied in the then-block:

| Rule | Then-block | Else-block |
|------|-----------|------------|
| `defined` | Remove `Undef` | `Undef` only |
| `isa` (Union) | Narrow to matched type | Subtract matched type from Union members |
| `ref` (Union) | Narrow to ref type | Subtract ref type from Union members |
| Truthiness | Remove `Undef` | No inverse |

The `unless` keyword reverses polarity: in `unless (defined($x))`, the body sees the inverse narrowing (i.e., `Undef`), and the else-block sees the direct narrowing.

### Literal Widening

When an unannotated variable is initialized with a literal, the type is **widened** from `Literal(value, Base)` to `Atom(Base)`. This reflects Perl's mutable `my` semantics -- a variable declared as `my $x = 0` may later hold any integer, not just `0`.

```
Expression        Literal Type            Widened Type
──────────────    ──────────────────────  ────────────
my $x = 0         Literal(0, Bool)        Int (Bool widens to Int)
my $x = 1         Literal(1, Bool)        Int (Bool widens to Int)
my $x = 42        Literal(42, Int)        Int
my $x = 3.14      Literal(3.14, Double)   Double
my $x = "hi"      Literal("hi", Str)      Str
```

The `Bool` to `Int` widening reflects Perl's treatment of `0` and `1` as numeric values. Widening is applied in the type environment construction phase and in local variable type collection. Expression-level inference (via `Infer->infer_expr`) is unaffected -- it still produces precise `Literal` types.

Widening also propagates into parameterized types: `[1, 2, 3]` infers as `ArrayRef[Int]`, not `ArrayRef[Literal(1, Int) | Literal(2, Int) | Literal(3, Int)]`.

---

## Builtin Prelude

`Typist::Prelude` provides standard type annotations for Perl builtin functions, establishing a baseline of type and effect information that the static analyzer can rely on without requiring user annotations.

### Installation

The prelude is installed during `Analyzer->analyze()` and `Workspace->new()` via `Prelude->install($registry)`. All entries are registered under the `CORE::` namespace, matching Perl's own namespace for builtins.

### Standard Effect Labels

Three standard effect labels are registered by the prelude so that the Checker does not report them as `UnknownEffect`:

| Label | Scope | Examples |
|-------|-------|---------|
| `IO` | I/O, time, randomness | `say`, `print`, `warn`, `open`, `close`, `rand`, `time`, `sleep` |
| `Exn` | Exceptions, evaluation, exit | `die`, `eval`, `exit` |
| `Decl` | Type and effect declarations | `typedef`, `newtype`, `struct`, `effect`, `typeclass`, `instance`, `datatype`, `enum`, `declare` |

### Builtin Annotations

The prelude annotates approximately 80 functions across several categories:

```
Category              Functions                                    Effect
────────────────────  ─────────────────────────────────────────    ──────
I/O operations        say, print, warn, open, close, read, write  ![IO]
Exception control     die, eval, exit                              ![Exn]
Typist declarations   typedef, newtype, struct, effect, ...        ![Decl]
String operations     length, substr, uc, lc, index, chr, ord     pure
Numeric operations    abs, int, sqrt, log, exp, sin, cos           pure
Array operations      push, pop, shift, unshift, reverse, sort     pure
Hash operations       keys, values, exists, delete                 pure
System interaction    system, exec, require, sleep, time           ![IO]
Randomness            rand, srand                                  ![IO]
```

Pure functions carry no effect annotation and can be called from any context without triggering `EffectMismatch`.

### Override with `declare`

User `declare` statements override prelude entries. Since `register_function` uses plain hash assignment, a later write replaces the prelude's default:

```perl
# Override the prelude's annotation for say
declare say => '(Str) -> Bool ![Console]';

# Override die with a custom effect label
declare die => '(Any) -> Never ![Abort]';

# Declare a pure override (removes the IO effect)
declare time => '() -> Int';
```

This mechanism allows projects to refine builtin annotations to match their specific effect vocabulary or to tighten parameter types beyond the prelude's permissive defaults.

### Integration with the Analyzer

The TypeChecker resolves builtin calls through a three-step lookup:

1. **Local**: check if the name matches a locally defined function.
2. **Cross-package**: if the name contains `::`, split and look up in the registry.
3. **CORE fallback**: look up `CORE::name` in the registry (prelude or `declare`).

The EffectChecker follows the same resolution order. Builtins that appear in the prelude with effect annotations (e.g., `say → ![IO]`) produce `EffectMismatch` if called from a pure annotated function. Builtins not in the prelude or declared pure are treated as effectless.

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
