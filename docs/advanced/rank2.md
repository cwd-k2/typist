# Rank-2 Polymorphism

Regular generic functions have rank-1 polymorphism: the caller chooses the concrete type for each type variable. Rank-2 polymorphism inverts this relationship -- a function can require that a callback argument work for *all* types, giving the callee the freedom to choose which types to instantiate it at.

---

## Rank-1 vs Rank-2

In rank-1 polymorphism, the type variable is fixed by the caller at the call site:

```typist
# Rank-1: the caller decides what T is.
# Calling identity(42) fixes T = Int.
sub identity :sig(<T>(T) -> T) ($x) { $x }
```

In rank-2 polymorphism, a function parameter is itself universally quantified. The callee can apply it at any type it chooses:

```typist
# Rank-2: the parameter $f must work for ALL types A.
# apply_twice gets to choose what A is, not the caller.
sub apply_twice :sig((forall A. (A) -> A, Int) -> Int) ($f, $x) {
    $f->($f->($x));
}
```

The key difference: `apply_twice` requires a *polymorphic* function as its first argument. A monomorphic function like `sub ($n) { $n + 1 }` cannot satisfy `forall A. (A) -> A` because it only works on numbers, not on all types.

---

## Syntax

The `forall` keyword introduces universally quantified type variables, followed by the variable names, a dot, and the quantified body type:

```
forall A. (A) -> A
forall A B. (A, B) -> A
forall A. (A, A) -> A
```

### Single variable

```typist
forall A. (A) -> A
```

A function that takes any type `A` and returns the same type. The identity function is the canonical example.

### Multiple variables

```typist
forall A B. (A, B) -> A
```

Multiple type variables are separated by spaces. This describes a function that takes two values of possibly different types and returns the first.

### Bounded quantification

Quantified variables can carry upper bounds:

```typist
forall A: Num. (A) -> A
```

Here `A` must be a subtype of `Num`. The bound restricts which types the variable can be instantiated to, while still requiring the function to be polymorphic within that range.

### Quantified parameters (the rank-2 pattern)

The most common rank-2 usage is a function whose parameter is itself quantified. The `forall` type appears inside the parameter list:

```typist
(forall A. (A) -> A, Int) -> Int
```

This is a function that takes two arguments: a polymorphic identity-like function, and an `Int`. The first argument must work for all types `A`.

---

## Subtyping Rules

Rank-2 types participate in the subtype relation with three key rules.

### Instantiation: `forall` subtypes concrete

A universally quantified type can be instantiated to any concrete type:

```typist
# (forall A. (A) -> A) <: (Int -> Int)
# The polymorphic identity can be used wherever a monomorphic Int -> Int is expected.
```

This is safe because a function that works for all types certainly works for `Int`.

### Anti-rule: concrete does not subtype `forall`

A monomorphic type cannot satisfy a universally quantified type:

```typist
# (Int -> Int) is NOT <: (forall A. (A) -> A)
# A function that only handles Int cannot claim to work for all types.
```

This is the fundamental asymmetry that gives rank-2 polymorphism its power. It also means `(Any) -> Any` does not satisfy `forall A. (A) -> A` -- even though `Any` is the top type, a function with a fixed `Any` signature is monomorphic.

### Subsumption: `forall` subtypes `forall`

Two quantified types can be compared by renaming variables and comparing their bodies. Bounds are checked contravariantly:

```typist
# (forall A. (A) -> A) <: (forall B. (B) -> B)
# Same structure, different variable names -- this holds.

# (forall A: Num. (A) -> A) <: (forall A. (A) -> A)
# A tighter bound (Num) subtypes a looser bound (none) -- the bounded
# version is more restrictive, so it satisfies the less restrictive requirement.
```

---

## Worked Example

Consider a function that applies a transformation to every element of a heterogeneous pair:

```typist
BEGIN {
    typedef Pair => 'Tuple[Any, Any]';
}

# map_pair requires a function that works for ALL types.
# This lets it safely apply $f to both the Int and the Str element.
sub map_pair :sig((forall A. (A) -> A, Tuple[Int, Str]) -> Tuple[Int, Str]) ($f, $pair) {
    [$f->($pair->[0]), $f->($pair->[1])];
}
```

The `forall A. (A) -> A` constraint on `$f` ensures that the same function can be applied to both the `Int` first element and the `Str` second element. Without rank-2, you could not express this requirement -- the type would have to pick one concrete type for the callback.

---

## Static Analysis

The static analyzer handles rank-2 types in several ways:

- **Parsing**: The parser recognizes `forall` as a keyword and constructs `Typist::Type::Quantified` nodes. `forall` can appear at the top level of a type expression or nested inside parameter positions.
- **Subtyping**: `Typist::Subtype` implements the instantiation, anti-rule, and subsumption rules described above. For instantiation, it uses structural matching (`Typist::Static::Unify`) to infer variable bindings and verify they satisfy any declared bounds.
- **Free variables**: The `free_vars` method correctly excludes bound variables from the set, preventing capture during substitution.

### Diagnostics

When a concrete type is passed where a `forall` type is expected, the checker reports a `TypeMismatch`:

```
TypeMismatch: expected forall A. (A) -> A, got (Int) -> Int
```

---

## Current Limitations

Rank-2 support is foundational. The checker handles the core subtyping rules, but some advanced patterns have limited coverage:

- **Inference for rank-2 arguments**: The static analyzer does not automatically infer that an anonymous sub satisfies a `forall` constraint. You may need explicit annotations in complex cases.
- **Deeply nested quantification**: Rank-3 and higher (quantification inside quantification inside parameters) is parsed and represented, but the checker may not fully trace all subtyping relationships.
- **Generic instantiation at rank-2 call sites**: When a rank-2 function is called, the checker instantiates the quantified type using structural unification. Complex type constructor patterns may not always unify successfully.

These limitations are practical rather than theoretical -- the type representation and subtyping rules are complete, and coverage will expand as the static analyzer matures.
