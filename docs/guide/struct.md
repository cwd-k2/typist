# Structs

Structs are nominal, immutable, blessed record types. They give you named constructors, field accessors, and type-checked immutable updates -- all with a compile-time identity that distinguishes them from plain hashrefs. Where a record type (`{ x => Int, y => Int }`) is purely structural, a struct carries a name: two structs with identical fields are different types if they have different names.

---

## Defining a Struct

Use `struct` inside a `BEGIN` block to define a struct type:

```typist
use v5.40;
use Typist;

BEGIN {
    struct Point => (x => 'Int', y => 'Int');
}
```

This registers a type named `Point`, generates a constructor function `Point(...)`, field accessors `->x` and `->y`, and a `Point::derive` function for immutable updates.

Field types are always strings. This is consistent with all Typist declarations -- type expressions are parsed by Typist's own parser, not by Perl.

---

## Construction

Structs use named arguments exclusively:

```typist
my $p = Point(x => 1, y => 2);
```

Positional arguments are not supported. The constructor returns a blessed, immutable hashref (`Typist::Struct::Point`).

### Structural Enforcement (Always Active)

Regardless of whether you use `use Typist` or `use Typist -runtime`, the constructor always checks:

- **Unknown fields** -- passing a field name not declared in the struct definition dies immediately.
- **Missing required fields** -- omitting a required field dies immediately.
- **Odd argument count** -- passing an odd number of arguments dies immediately.

These are cheap structural checks that catch API misuse without any runtime type overhead:

```typist
eval { Point(x => 1) };
# Dies: Typist: Point() — missing required field 'y'

eval { Point(x => 1, y => 2, z => 3) };
# Dies: Typist: Point() — unknown field 'z'
```

### Type Validation (Runtime Mode Only)

With `use Typist -runtime`, the constructor additionally validates that each field value matches its declared type via `contains()`:

```typist
use Typist -runtime;

eval { Point(x => "one", y => 2) };
# Dies: Typist: Point() — field 'x' expected Int, got one
```

In static-only mode (`use Typist`), this validation is performed by the static analyzer at CHECK time instead.

---

## Field Accessors

Each field produces a read-only accessor method:

```typist
my $p = Point(x => 1, y => 2);
say $p->x;   # 1
say $p->y;   # 2
```

There are no setter methods. Struct instances are immutable.

---

## Optional Fields

Use `optional(field => 'Type')` to declare fields that can be omitted at construction:

```typist
BEGIN {
    struct Item => (
        name => 'Str',
        optional(desc => 'Str'),
    );
}

my $item = Item(name => "Widget");
say $item->name;           # "Widget"
say $item->desc // "n/a";  # "n/a" (desc is undef)

my $full = Item(name => "Widget", desc => "A fine widget");
say $full->desc;           # "A fine widget"
```

Optional fields that are omitted default to `undef`. When present, they must match the declared type (checked in `-runtime` mode or by the static analyzer).

The `optional` function is a simple syntax helper defined in `Typist.pm`. It transforms the field name by appending `?` internally: `optional(desc => 'Str')` becomes `("desc?", "Str")` in the field pair list.

---

## Immutable Derive

`Name::derive($instance, field => value, ...)` creates a **new** instance of the same struct type with the specified fields updated. The original instance is unchanged:

```typist
my $p1 = Point(x => 1, y => 2);
my $p2 = Point::derive($p1, y => 10);

say $p1->y;   # 2  -- original unchanged
say $p2->y;   # 10 -- new instance
say $p2->x;   # 1  -- unmodified fields carried over
```

`derive` rejects unknown fields, just like the constructor:

```typist
eval { Point::derive($p1, z => 99) };
# Dies: Unknown field 'z' for struct Point
```

This is the only way to "update" a struct. There are no setter methods and no in-place mutation.

---

## Generic Structs

Structs can be parameterized with type variables. Quote the name when it has type parameters, because `[` would break Perl's bareword parsing:

```typist
BEGIN {
    struct 'Pair[T, U]' => (fst => 'T', snd => 'U');
    struct 'Box[T]'     => (val => 'T');
}
```

### Construction and Type Inference

Type arguments are inferred from field values at construction time:

```typist
my $p = Pair(fst => 42, snd => "hi");   # Pair[Int, Str]
my $b = Box(val => 3.14);               # Box[Double]
```

You do not explicitly supply type arguments. The constructor infers them from the runtime types of the field values (in `-runtime` mode) or from the static types at the call site (in static mode).

### Accessor Resolution

Accessors on generic structs resolve through the inferred type arguments:

```typist
my $p = Pair(fst => 42, snd => "hi");
# $p->fst : Int   (T resolved to Int)
# $p->snd : Str   (U resolved to Str)
```

The static analyzer performs the same substitution: if `$p` is known to be `Pair[Int, Str]`, then `$p->fst` is inferred as `Int`.

---

## Bounded Generic Structs

Generic struct parameters can carry bounds or typeclass constraints:

```typist
BEGIN {
    struct 'NumBox[T: Num]' => (value => 'T');
    struct 'ShowBox[T: Show]' => (value => 'T');
}
```

### Type Bound

`T: Num` means `T` must be a subtype of `Num`. Constructing `NumBox(value => "hello")` is a type error because `Str` is not a subtype of `Num`.

### Typeclass Constraint

`T: Show` means `T` must have a registered `Show` instance. The disambiguation rule is the same as for function generics: if the name after `:` is a registered typeclass, it is a typeclass constraint; otherwise it is a type bound.

### Static Checking

Bounded generic struct constructors are checked at call sites by the static analyzer. In `-runtime` mode, bounds are additionally validated at construction time:

```typist
use Typist -runtime;

my $ok  = NumBox(value => 42);       # ok: Int <: Num
eval { NumBox(value => "hello") };   # dies: Str does not satisfy bound Num
```

---

## Struct Subtyping

Structs use nominal identity. The subtyping rules are:

| Relation | Holds? | Reason |
|----------|--------|--------|
| `Point <: Point` | Yes | Same name (nominal identity) |
| `Point <: { x => Int, y => Int }` | Yes | Struct is compatible with its structural shape |
| `{ x => Int, y => Int } <: Point` | **No** | A record is never a subtype of a struct (nominal barrier) |
| `Box[Bool] <: Box[Int]` | Yes | Generic struct subtyping is covariant (`Bool <: Int`) |
| `Pair[Int, Str] <: Pair[Int, Int]` | **No** | `Str` is not a subtype of `Int` |

The key principle: structs can be used where a matching record shape is expected (because a struct *is* a record with additional identity), but a plain hashref matching the shape cannot be used where a struct is expected.

### Covariant Generic Subtyping

Generic struct subtyping follows the type arguments covariantly:

```typist
# Bool <: Int, therefore:
# Box[Bool] <: Box[Int]

# Int <: Num, therefore:
# Pair[Int, Str] <: Pair[Num, Str]
```

---

## Structs vs Records vs Newtypes

| Feature | Record | Struct | Newtype |
|---------|--------|--------|---------|
| Identity | Structural (shape) | Nominal (name) | Nominal (name) |
| Values | Plain hashrefs | Blessed, immutable | Blessed scalar refs |
| Accessors | `$r->{field}` | `$s->field` | `Name::coerce($v)` |
| Subtyping | Width subtyping | Nominal + covariant generics | Strict nominal |
| Generics | No | Yes | No |
| Immutable update | Manual | `Name::derive(...)` | N/A |

Use records for lightweight structural shapes (function parameters, intermediate data). Use structs when you need nominal identity, accessor methods, immutable derivation, or generics. Use newtypes for opaque scalar wrappers where the inner value should not be directly accessible.

---

## Complete Example

```typist
use v5.40;
use Typist;

BEGIN {
    struct Point => (x => 'Int', y => 'Int');
    struct 'Pair[T, U]' => (fst => 'T', snd => 'U');
    struct Config => (
        host  => 'Str',
        port  => 'Int',
        optional(debug => 'Bool'),
        optional(label => 'Str'),
    );
}

# Basic construction and access
my $origin = Point(x => 0, y => 0);
say $origin->x;   # 0

# Immutable derive
my $moved = Point::derive($origin, x => 5);
say $moved->x;     # 5
say $origin->x;    # 0 (unchanged)

# Optional fields
my $cfg = Config(host => "localhost", port => 8080);
say $cfg->host;                # "localhost"
say $cfg->debug // "default";  # "default"

my $debug_cfg = Config(host => "0.0.0.0", port => 443, debug => 1);
say $debug_cfg->debug;        # 1

# Generic struct
my $p = Pair(fst => 42, snd => "hello");
say $p->fst;    # 42
say $p->snd;    # "hello"

# Using structs in typed functions
sub distance :sig((Point, Point) -> Double) ($a, $b) {
    sqrt(($a->x - $b->x) ** 2 + ($a->y - $b->y) ** 2);
}

say distance(Point(x => 0, y => 0), Point(x => 3, y => 4));   # 5
```

---

## Next

- [ADTs and Pattern Matching](adt.md) -- tagged unions built with `datatype`, `enum`, and `match`
