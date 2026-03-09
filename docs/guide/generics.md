# Generics

Generics (parametric polymorphism) let you write functions and data structures that work uniformly over any type, while preserving type safety. Instead of accepting `Any` and losing all type information, a generic function declares type variables that the checker binds to concrete types at each call site.

---

## Basic Generic Functions

Declare type parameters in `<>` before the parameter list:

```typist
use v5.40;
use Typist;

sub identity :sig(<T>(T) -> T) ($x) {
    $x;
}

sub first :sig(<T>(ArrayRef[T]) -> T) ($arr) {
    $arr->[0];
}
```

`T` is a type variable. When you call `identity(42)`, Typist infers `T = Int` and checks that the return type is `Int`. When you call `first(["a", "b"])`, it infers `T = Str`.

You never write the type argument explicitly -- it is always inferred from the arguments.

### Multiple Type Parameters

Use comma-separated names for independent type variables:

```typist
sub pair :sig(<T, U>(T, U) -> Tuple[T, U]) ($a, $b) {
    [$a, $b];
}

sub swap :sig(<T, U>(Tuple[T, U]) -> Tuple[U, T]) ($t) {
    [$t->[1], $t->[0]];
}

my $p = pair(42, "hello");    # Tuple[Int, Str]
my $s = swap($p);             # Tuple[Str, Int]
```

---

## Bounded Quantification

Constrain a type variable with an upper bound using `T: Bound`:

```typist
sub max_of :sig(<T: Num>(T, T) -> T) ($a, $b) {
    $a > $b ? $a : $b;
}
```

`T: Num` means `T` must be a subtype of `Num`. This:

- **Allows**: `max_of(3, 4)` (Int <: Num), `max_of(1.5, 2.5)` (Double <: Num)
- **Rejects**: `max_of("a", "b")` (Str is not <: Num)

Within the function body, `T` is treated as `Num` for the purposes of static analysis, so numeric operations are valid.

### Strict Bounds

You can use any type as a bound, not just `Num`:

```typist
sub increment :sig(<T: Int>(T) -> T) ($x) {
    $x + 1;
}

increment(10);      # ok: Int <: Int
increment(3.14);    # error: Double is not <: Int
```

### How Bounds Are Checked

- **Static**: after unifying type variables with actual argument types, the static analyzer checks `is_subtype(inferred_T, bound)` for each bounded variable. A violation produces a `TypeMismatch` diagnostic.
- **Runtime** (with `-runtime`): the same check runs at call time, dying on violation.

---

## Typeclass Constraints

When the name after `:` is a registered typeclass (rather than a type), it becomes a typeclass constraint instead of a type bound:

```typist
BEGIN {
    typeclass Show => 'T', +{
        show => '(T) -> Str',
    };
    instance Show => 'Int', +{
        show => sub ($v) { "$v" },
    };
}

sub show_it :sig(<T: Show>(T) -> Str) ($x) {
    Show::show($x);
}
```

The static analyzer checks that the inferred type argument has a registered instance of the specified typeclass. If not, it produces a diagnostic.

### Disambiguation Rule

The syntax `T: X` is overloaded. Typist disambiguates by consulting the Registry:

| What `X` is | Interpretation | Check performed |
|-------------|---------------|-----------------|
| A registered typeclass | Typeclass constraint | `resolve_instance("X", actual_type)` |
| A registered type (or unregistered) | Type bound | `is_subtype(actual_type, X)` |

This happens automatically -- you use the same syntax for both.

---

## Compound Constraints

Combine multiple constraints with `+`:

```typist
sub display_max :sig(<T: Num + Show>(T, T) -> Str) ($a, $b) {
    Show::show($a > $b ? $a : $b);
}
```

Each part of a `+`-separated constraint is disambiguated independently:

- `Num` -- not a typeclass, so it is a type bound
- `Show` -- a registered typeclass, so it is a typeclass constraint

Both are checked at the call site. The call `display_max(3, 4)` succeeds if `Int <: Num` and there is a `Show` instance for `Int`.

### Multiple Typeclass Constraints

```typist
sub sorted_show :sig(<T: Ord + Show>(ArrayRef[T]) -> Str) ($arr) {
    # T must have both Ord and Show instances
    ...
}
```

---

## Bounded Generics on Effects

The same bound syntax applies to effect type parameters. See [Algebraic Effects — Bounded Type Parameters](effects.md#bounded-type-parameters) for details.

---

## Generics with Composite Types

Type variables can appear inside parameterized types:

```typist
sub head_or_default :sig(<T>(ArrayRef[T], T) -> T) ($arr, $default) {
    @$arr ? $arr->[0] : $default;
}

sub zip :sig(<T, U>(ArrayRef[T], ArrayRef[U]) -> ArrayRef[Tuple[T, U]]) ($xs, $ys) {
    my $len = @$xs < @$ys ? @$xs : @$ys;
    [ map { [$xs->[$_], $ys->[$_]] } 0 .. $len - 1 ];
}

say head_or_default([1, 2, 3], 0);          # 1
say head_or_default([], "none");            # "none"

my $zipped = zip([1, 2], ["a", "b"]);
# $zipped : ArrayRef[Tuple[Int, Str]]
```

---

## Generic Structs

Structs can be parameterized over type variables (covered in detail in [Structs](struct.md)):

```typist
BEGIN {
    struct 'Pair[T, U]' => (fst => 'T', snd => 'U');
    struct 'Box[T]'     => (val => 'T');
}

my $p = Pair(fst => 42, snd => "hello");   # Pair[Int, Str]
say $p->fst;                                # 42 (typed as Int)
```

Bounded generic structs combine generics with type bounds:

```typist
BEGIN {
    struct 'NumBox[T: Num]' => (value => 'T');
}
```

---

## Generic ADTs

ADTs can also be parameterized (covered in detail in [ADTs](adt.md)):

```typist
BEGIN {
    datatype 'Option[T]' =>
        Some => '(T)',
        None => '()';

    datatype 'Result[T]' =>
        Ok  => '(T)',
        Err => '(Str)';
}

my $x = Some(42);      # Option[Int]
my $e = Err("fail");   # Result[?]
```

---

## How Generic Inference Works

Understanding the inference pipeline helps when debugging type errors.

### Static Analysis (CHECK Phase / LSP)

1. **Parse**: the `:sig()` annotation is parsed to extract type parameters, parameter types, return type, and effects.
2. **Infer arguments**: at each call site, the static analyzer infers the type of each argument expression.
3. **Unify**: formal parameter types are structurally unified with actual argument types to extract bindings for type variables. If the same variable appears in multiple parameters, the inferred types are combined via LUB (least upper bound).
4. **Check bounds**: for each bounded variable `T: Bound`, the analyzer checks `is_subtype(binding[T], Bound)`.
5. **Check typeclass constraints**: for each typeclass constraint `T: TC`, the analyzer calls `resolve_instance("TC", binding[T])`.
6. **Substitute and verify**: bindings are substituted into formal types, and concrete subtype relations are verified against actual argument types.

If any step fails, a diagnostic is produced (TypeMismatch, ArityMismatch, etc.).

### Runtime (with `-runtime`)

Generic function call-site checking is performed by the static analyzer. At runtime, type validation happens only at constructor boundaries (struct constructors, datatype constructors) where `-runtime` enables `contains()` checks.

---

## Common Patterns

### Wrapper / Container

```typist
sub wrap :sig(<T>(T) -> ArrayRef[T]) ($x) {
    [$x];
}

sub unwrap :sig(<T>(ArrayRef[T]) -> T) ($arr) {
    $arr->[0];
}
```

### Transform

```typist
sub map_maybe :sig(<T, U>(Maybe[T], CodeRef[T -> U]) -> Maybe[U]) ($opt, $f) {
    defined $opt ? $f->($opt) : undef;
}
```

### Constrained Operations

```typist
sub clamp :sig(<T: Num>(T, T, T) -> T) ($val, $lo, $hi) {
    $val < $lo ? $lo : $val > $hi ? $hi : $val;
}
```

---

## Troubleshooting

### "TypeMismatch: T does not satisfy bound Num"

You called a bounded generic function with an argument whose type does not satisfy the bound. Check that the argument type is a subtype of the declared bound.

### "no instance of Show for ..."

You called a function with a typeclass constraint, but the inferred type argument does not have a registered instance. Add an `instance` declaration for the missing type.

### Free Type Variables

If the static analyzer cannot infer a type variable from the arguments (e.g., it only appears in the return type), the variable resolves to `Any`. This is by design -- Typist uses gradual typing semantics for unresolved generics.

---

## Next

- [Type Classes](typeclass.md) -- ad-hoc polymorphism with instance dispatch and superclass hierarchies
