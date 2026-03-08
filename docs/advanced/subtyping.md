# Subtyping Rules

Typist's subtype relation determines when a value of one type can be used where another type is expected. It is the foundation of type checking: every assignment, function call, and return statement is validated against these rules.

This page documents the complete subtype relation. Understanding it is useful for diagnosing type errors, designing type hierarchies, and working with advanced features like unions, records, and quantified types.

---

## Notation

Throughout this page, `A <: B` means "A is a subtype of B" -- a value of type `A` can be used wherever type `B` is expected. `A </: B` means the subtype relation does not hold.

---

## Atom Hierarchy

The built-in primitive types form a linear chain plus two independent branches:

```
              Any
            / | \ \
         Str Num  | Void
          |   |   |
          | Double|
          |   |   |
          | Int   |
          |   |   |
          | Bool  |
          |       |
          +---+---+
              |
            Never
```

| Rule | Example |
|------|---------|
| `Bool <: Int` | A boolean is an integer |
| `Int <: Double` | An integer is a double |
| `Double <: Num` | A double is numeric |
| `Num <: Any` | All numerics are Any |
| `Str <: Any` | Strings are Any |
| `Undef <: Any` | Undef is Any |
| `Void <: Any` | Void subtypes only Any |

`Str` and `Num` are independent -- neither subtypes the other. `Str </: Num` and `Num </: Str`.

---

## Universal Rules

These rules apply regardless of type constructor.

### Identity

```
T <: T
```

Every type is a subtype of itself.

### Top

```
T <: Any    (for all T)
```

`Any` is the top type. Every type subtypes `Any`.

### Bottom

```
Never <: T    (for all T)
```

`Never` is the bottom type. It subtypes everything. No value inhabits `Never` -- it represents unreachable code (e.g., a function that always throws).

### Void

```
Void <: Any    (only)
```

`Void` indicates no meaningful return value. It subtypes `Any` but nothing else. `Void </: Int`, `Void </: Str`, etc.

---

## Literal Types

Literal types represent specific values: `"hello"` (a literal `Str`), `42` (a literal `Int`), `true` (a literal `Bool`).

### Literal to Atom

```
Literal(v, B) <: B
```

A literal subtypes its base atom type. `Literal(42, Int) <: Int`.

### Literal to Literal

```
Literal(v1, B1) <: Literal(v2, B2)    iff v1 == v2 AND B1 <: B2
```

Two literals are in a subtype relationship only if they have the same value and the base types are compatible. `Literal(1, Bool) <: Literal(1, Int)` because `Bool <: Int` and the value is the same.

### Atom to Literal

```
T </: Literal(v, B)    (unless T is also Literal(v, B'))
```

A non-literal type never subtypes a literal type. `Int </: Literal(42, Int)` -- the set of all integers is not a subset of the singleton `{42}`.

---

## Type Aliases

Type aliases (`typedef`) are transparent. The alias is resolved before comparison:

```typist
BEGIN { typedef Name => 'Str'; }
# Name <: Str  and  Str <: Name  (they are the same type after resolution)
```

Resolution uses the Registry and handles chains: if `A` aliases `B` which aliases `C`, comparing `A <: X` first resolves `A` to `C`, then compares `C <: X`.

---

## Union Types

A union `T | U` represents values that belong to either `T` or `U`.

### Union as subtype

```
T | U <: S    iff T <: S AND U <: S
```

Every member of the union must subtype the target. This is the safe direction -- if all members fit, the union fits.

```typist
# Int | Bool <: Num
# because Int <: Num AND Bool <: Int <: Num
```

### Union as supertype

```
S <: T | U    iff S <: T OR S <: U
```

It suffices for the value to fit any one member of the union.

```typist
# Int <: Int | Str
# because Int <: Int
```

---

## Intersection Types

An intersection `T & U` represents values that belong to both `T` and `U`.

### Intersection as subtype

```
T & U <: S    iff T <: S OR U <: S
```

If the value satisfies both `T` and `U`, it certainly satisfies either one individually.

### Intersection as supertype

```
S <: T & U    iff S <: T AND S <: U
```

To be a subtype of an intersection, the value must satisfy all members.

---

## Parameterized Types

Parameterized types like `ArrayRef[T]` and `HashRef[K, V]` are covariant in all parameters:

```
ArrayRef[T] <: ArrayRef[U]    iff T <: U
HashRef[K1, V1] <: HashRef[K2, V2]    iff K1 <: K2 AND V1 <: V2
```

Examples:

```typist
# ArrayRef[Int] <: ArrayRef[Num]     (because Int <: Num)
# ArrayRef[Num] </: ArrayRef[Int]    (Num is not a subtype of Int)
# HashRef[Str, Int] <: HashRef[Str, Num]
```

Two parameterized types with different base constructors are never in a subtype relationship:

```typist
# ArrayRef[Int] </: HashRef[Str, Int]    (different constructors)
```

> **Note on soundness**: Covariance for mutable containers is technically unsound (e.g., an `ArrayRef[Int]` used as `ArrayRef[Num]` could have a `Double` pushed into it). Typist accepts this trade-off for practical usability, following the same approach as TypeScript.

---

## Function Types

Function types follow the standard variance rules from type theory.

### Parameters: contravariant

```
(A) -> R <: (B) -> R    iff B <: A
```

A function that accepts a *broader* input type is substitutable for one that accepts a *narrower* type. The parameter position is contravariant (the direction reverses).

```typist
# (Num) -> Str <: (Int) -> Str
# A function accepting any Num can be used where one accepting only Int is expected.
```

### Return type: covariant

```
(A) -> R <: (A) -> S    iff R <: S
```

A function that returns a *narrower* type is substitutable for one that returns a *broader* type.

```typist
# (Int) -> Int <: (Int) -> Num
# A function returning Int can be used where one returning Num is expected.
```

### Effects: covariant

```
(A) -> R ![E1] <: (A) -> R ![E2]    iff E1 <: E2
```

A function with fewer effects can be used where more effects are permitted. Effect subtyping is based on label set inclusion (see [Row Subtyping](#row-subtyping) below).

### Arity: strict

Function types must have the same number of parameters. `(Int) -> Str </: (Int, Int) -> Str`.

---

## Record Types

Records are structural types with named fields. They support both width and depth subtyping.

### Width subtyping (more fields subtypes fewer)

```
{ a: T, b: U, c: V } <: { a: T, b: U }
```

A record with more fields can be used where fewer fields are expected. The extra fields are simply ignored.

### Depth subtyping (covariant field types)

```
{ a: T } <: { a: U }    iff T <: U
```

Each field type is compared covariantly.

### Optional field rules

```
Required subtypes optional:    k: T  <:  k?: T
```

A required field satisfies an optional field requirement. The converse does not hold -- an optional field cannot satisfy a required field, because the value might be missing.

When the super record has an optional field:
- If the sub record has it (required or optional), the field types must be compatible.
- If the sub record omits it entirely, that is acceptable (the field is optional after all).

### Record to HashRef

```
{ a: T, b: T } <: HashRef[Str, T]    iff all field values <: T
```

A record with homogeneous value types subtypes the corresponding `HashRef`. This enables passing record literals where a `HashRef` is expected.

---

## Struct Types (Nominal)

Structs use **nominal** subtyping -- two structs are in a subtype relationship only if they have the same name.

```typist
BEGIN {
    struct Point  => (x => 'Int', y => 'Int');
    struct Vector => (x => 'Int', y => 'Int');
}
# Point </: Vector   (different names, even though identical fields)
# Point <: Point     (same name)
```

### Struct subtypes Record (structural escape hatch)

A struct is a subtype of its structural record shape:

```typist
# Point <: { x => Int, y => Int }
```

This allows functions that accept a record shape to work with any struct that has the right fields.

### Record does not subtype Struct (nominal barrier)

```typist
# { x => Int, y => Int } </: Point
```

A plain hashref with the right shape cannot masquerade as a named struct. This is the nominal guarantee -- if a function expects a `Point`, only a `Point` constructor call will do.

### Generic struct covariance

Generic structs are covariant in their type arguments:

```typist
BEGIN {
    struct 'Box[T]' => (value => 'T');
}
# Box[Int] <: Box[Num]    (because Int <: Num)
```

---

## Newtype and Data Types (Nominal)

Like structs, newtypes and data types use nominal identity:

```typist
BEGIN {
    newtype UserId => 'Int';
    newtype GroupId => 'Int';
}
# UserId </: GroupId    (different names)
# UserId <: UserId     (same name)
# UserId </: Int       (newtype is not its underlying type)
# Int </: UserId       (no implicit wrapping)
```

Data types (from `datatype`/`enum`) follow the same rule, with covariant type arguments when present:

```typist
BEGIN {
    datatype 'Maybe[T]' => +{ Some => '(T)', None => '()' };
}
# Maybe[Int] <: Maybe[Num]    (covariant)
```

---

## Quantified Types (forall)

See [Rank-2 Polymorphism](rank2.md) for full coverage. The key subtyping rules:

### Instantiation

```
(forall A. T) <: U
```

A universally quantified type can be instantiated to match a concrete type. The checker uses structural unification to find a valid binding for the quantified variables.

```typist
# (forall A. (A) -> A) <: (Int) -> Int
```

### Anti-rule

```
U </: (forall A. T)    (when U is not quantified)
```

A concrete type cannot satisfy a universal requirement.

```typist
# (Int) -> Int </: (forall A. (A) -> A)
```

### Subsumption

```
(forall A. T) <: (forall B. U)
```

Two quantified types are compared by renaming variables and checking the bodies. Bounds are checked contravariantly.

---

## Row Subtyping

Effect rows use label set inclusion:

```
Row(A, B, C) <: Row(A, B)
```

A row with more labels subtypes a row with fewer labels. This means a function that performs effects `{A, B, C}` can be used where `{A, B}` is expected -- it simply performs *more* effects, which is safe because the handler for the larger set necessarily handles all the smaller set's labels.

Eff types (the `![...]` annotation) delegate to their inner row:

```
!E1 <: !E2    iff E1.row <: E2.row
```

---

## Complete Rule Table

| # | Rule | Notation | Description |
|---|------|----------|-------------|
| 1 | Identity | `T <: T` | Every type is a subtype of itself |
| 2 | Top | `T <: Any` | Every type subtypes Any |
| 3 | Bottom | `Never <: T` | Never subtypes everything |
| 4 | Void | `Void <: Any` only | Void only subtypes Any |
| 5 | Atom chain | `Bool <: Int <: Double <: Num <: Any` | Numeric hierarchy |
| 6 | Atom independent | `Str <: Any` | Str is independent from numerics |
| 7 | Literal-Atom | `Literal(v, B) <: B` | Literals subtype their base |
| 8 | Literal-Literal | `L1 <: L2` iff `val= && base<:` | Same value, base subtypes |
| 9 | Alias | resolve then compare | Transparent resolution |
| 10 | Union (sub) | `T|U <: S` iff `T<:S` AND `U<:S` | All members must subtype |
| 11 | Union (super) | `S <: T|U` iff `S<:T` OR `S<:U` | Any member suffices |
| 12 | Intersection (sub) | `T&U <: S` iff `T<:S` OR `U<:S` | Any member suffices |
| 13 | Intersection (super) | `S <: T&U` iff `S<:T` AND `S<:U` | All must subtype |
| 14 | Param covariant | `P[A] <: P[B]` iff `A<:B` | Same base, covariant args |
| 15 | Func params | `(A)->R <: (B)->R` iff `B<:A` | Contravariant parameters |
| 16 | Func return | `(A)->R <: (A)->S` iff `R<:S` | Covariant return |
| 17 | Func effects | `!E1 <: !E2` iff `E1<:E2` | Covariant effects |
| 18 | Record width | `{a,b,c} <: {a,b}` | More fields subtypes fewer |
| 19 | Record depth | `{a:T} <: {a:U}` iff `T<:U` | Field covariance |
| 20 | Record optional | `k:T <: k?:T` | Required subtypes optional |
| 21 | Struct nominal | `S <: S` iff same name | Name identity |
| 22 | Struct generic | `S[A] <: S[B]` iff `A<:B` | Covariant type args |
| 23 | Struct-Record | `S <: {fields}` | Structural compatibility |
| 24 | Record-Struct | `{fields} </: S` | Nominal barrier |
| 25 | Newtype | `N <: N` iff same name | Name identity |
| 26 | Data | `D <: D` iff same name | Name identity + covariant args |
| 27 | Quantified inst. | `(forall A. T) <: U` | Instantiation |
| 28 | Quantified anti | `U </: (forall A. T)` | Mono cannot satisfy forall |
| 29 | Quantified sub. | `(forall A. T) <: (forall B. U)` | Rename and compare bodies |
| 30 | Row | `Row(A,B) <: Row(A)` | Label set inclusion |
| 31 | Record-HashRef | `{a:T,b:T} <: HashRef[Str,T]` | Homogeneous values |

---

## Key Design Principles

**Nominal vs structural.** Structs, newtypes, and data types are nominal -- identity comes from their name, not their shape. Records, unions, intersections, and parameterized types are structural -- identity comes from their shape. This dual system lets you choose the right tool: nominal types for domain boundaries (a `UserId` is not a `GroupId`), structural types for data flow (any `{name: Str}` will do).

**Contravariant function parameters.** This is the standard type-theoretic rule and it may feel counterintuitive at first. Think of it this way: a function that accepts `Num` is *more permissive* than one that accepts `Int`, so it can substitute for the `Int`-accepting function -- not the other way around.

**Covariant everything else.** Return types, parameterized type arguments, effect rows, and record fields are all covariant. More specific subtypes less specific.

**Gradual compatibility.** When a type cannot be resolved (unknown alias, unregistered type), the checker falls back to permissive behavior rather than hard errors. This is consistent with Typist's gradual typing philosophy.
