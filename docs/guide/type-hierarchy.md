# Type Hierarchy

This page covers every type in Typist: the nine primitive atoms, compound types, unions, intersections, records, function types, and literal types. Understanding the subtype relationships between these types is essential for writing correct annotations and interpreting diagnostics.

---

## Primitive Types (Atoms)

Typist provides nine primitive types organized in a subtype hierarchy:

```
                Any         Top type: every type is a subtype of Any
              / | \ \
           Str Num  | Void   Void: no meaningful return value
            |   |   |
            | Double |       Double: floating-point numbers
            |   |    |
            |  Int  Undef    Undef: Perl's undef
            |   |
            | Bool           Bool: boolean values
            |
            +--+--+
                |
              Never          Bottom type: subtype of everything
```

| Type | Description | Perl values |
|------|-------------|-------------|
| `Any` | Top type -- accepts all values | Everything |
| `Void` | No meaningful return value | Used only as a return type |
| `Never` | Bottom type -- no values inhabit it | Unreachable code (e.g., after `die`) |
| `Undef` | Perl's `undef` | `undef` only |
| `Bool` | Boolean | `1`, `0`, `''` |
| `Int` | Integer | Whole numbers (`42`, `-7`, `0`) |
| `Double` | Floating-point | Numbers with a fractional part (`3.14`, `-0.5`) |
| `Num` | Numeric supertype | Any numeric value |
| `Str` | String | Any defined non-reference scalar |

### Subtype chains

```
Bool <: Int <: Double <: Num <: Any
Str <: Any
Undef <: Any
Void <: Any
Never <: T   (for all types T)
```

Key observations:

- **The numeric chain is linear.** Every `Bool` is an `Int`, every `Int` is a `Double`, every `Double` is a `Num`. This means a function expecting `Num` accepts `Bool`, `Int`, or `Double`.
- **`Str` is independent from the numeric branch.** `Str` and `Num` are siblings under `Any`, not subtypes of each other. A function expecting `Num` rejects a `Str`, and vice versa.
- **`Undef` is its own branch.** `Undef` is not `Str`, not `Int`, not `Bool`. To accept `undef`, use `Maybe[T]` (which desugars to `T | Undef`) or an explicit union.
- **`Never` is the bottom.** It is a subtype of every type but has no inhabitants. It is the return type of functions that never return (e.g., `die`).

### Usage

```typist
my $n :sig(Num)   = 42;      # ok: Int <: Num
my $n :sig(Num)   = 3.14;    # ok: Double <: Num
my $s :sig(Str)   = "hello"; # ok
my $b :sig(Bool)  = 1;       # ok
my $u :sig(Undef) = undef;   # ok
my $a :sig(Any)   = [1,2,3]; # ok: Any accepts everything
```

---

## Compound Types

### Parameterized containers

| Constructor | Example | Description |
|-------------|---------|-------------|
| `ArrayRef[T]` | `ArrayRef[Int]` | Reference to an array where all elements are `T` |
| `HashRef[K, V]` | `HashRef[Str, Int]` | Reference to a hash with key type `K` and value type `V` |
| `Tuple[T, U, ...]` | `Tuple[Int, Str]` | Fixed-length array ref with per-position types |
| `Ref[T]` | `Ref[Int]` | Scalar reference to a value of type `T` |
| `Maybe[T]` | `Maybe[Str]` | Sugar for `T | Undef` -- nullable type |
| `CodeRef[A -> R]` | `CodeRef[Int -> Str]` | Function reference with signature `A -> R` |
| `Array[T]` | `Array[Int]` | List type -- the result of list-producing expressions |
| `Hash[K, V]` | `Hash[Str, Int]` | List type -- the result of hash-producing expressions |

```typist
my $nums :sig(ArrayRef[Int])       = [1, 2, 3];
my $map  :sig(HashRef[Str, Int])   = +{ a => 1, b => 2 };
my $pair :sig(Tuple[Str, Int])     = ["Alice", 30];
my $ref  :sig(Ref[Int])           = \42;
my $opt  :sig(Maybe[Str])         = undef;     # ok: Str | Undef
my $cb   :sig(CodeRef[Int -> Str]) = sub ($n) { "$n" };
```

### Array vs ArrayRef

This is a common point of confusion. `Array[T]` and `ArrayRef[T]` are fundamentally different types:

| | `ArrayRef[T]` | `Array[T]` |
|---|---|---|
| What it is | A scalar reference to an array | A list-producing expression |
| Perl context | Scalar | List |
| Created by | `[1, 2, 3]` | `map { ... } @list`, `grep { ... } @list`, `sort @list` |
| Use in annotations | Variables, struct fields, parameters | Appears in inferred return types of list operations |
| Subtype relation | Neither is a subtype of the other | Neither is a subtype of the other |

For variables, parameters, and data structures, you almost always want `ArrayRef[T]`. `Array[T]` appears in inferred types when the static analyzer tracks list operations:

```typist
my @words = ("hello", "world");
my @upper = map { uc($_) } @words;     # inferred: Array[Str]
my $upper = [map { uc($_) } @words];   # inferred: ArrayRef[Str]
```

The same distinction applies to `Hash[K, V]` vs `HashRef[K, V]`.

### Parameterized subtyping

Parameterized types are **covariant** in all their parameters:

```
ArrayRef[Int] <: ArrayRef[Double]        # because Int <: Double
ArrayRef[Bool] <: ArrayRef[Num]          # because Bool <: Int <: Double <: Num
HashRef[Str, Int] <: HashRef[Str, Num]   # value covariance
Tuple[Bool, Str] <: Tuple[Int, Str]      # per-position covariance
```

### Nesting

Types compose freely:

```typist
my $matrix :sig(ArrayRef[ArrayRef[Int]]) = [[1, 2], [3, 4]];
my $users  :sig(ArrayRef[{ name => Str, age => Int }]) = [
    +{ name => "Alice", age => 30 },
    +{ name => "Bob",   age => 25 },
];

BEGIN {
    typedef Json => 'Str | Num | Bool | Undef
                    | ArrayRef[Json]
                    | HashRef[Str, Json]';
}
```

---

## Union Types

`T | U` -- a value that belongs to either `T` or `U`.

```typist
my $id :sig(Int | Str) = 42;
$id = "ABC-123";               # ok: Str is a member

BEGIN { typedef Result => 'Str | Undef'; }
```

### Properties

- **Flattened**: `(A | B) | C` normalizes to `A | B | C`
- **Deduplicated**: structurally equal members are collapsed
- **Single-member collapse**: `Union(T)` simplifies to `T`

### Subtyping rules

```
T | U <: S     iff  T <: S  AND  U <: S     (every member must subtype S)
S <: T | U     iff  S <: T  OR   S <: U     (S need only subtype one member)
```

Examples:

```
Int | Str <: Any            # true: both Int <: Any and Str <: Any
Int <: Int | Str            # true: Int <: Int
Bool <: Int | Str           # true: Bool <: Int
Double <: Int | Str         # false: Double </: Int and Double </: Str
```

### Maybe[T]

`Maybe[T]` is syntactic sugar for `T | Undef`. It is the standard way to express nullable types:

```typist
my $email :sig(Maybe[Str]) = undef;
$email = "alice@example.com";    # ok: Str
$email = undef;                  # ok: Undef
```

---

## Intersection Types

`T & U` -- a value that satisfies both `T` and `U` simultaneously.

```typist
BEGIN { typedef ReadWrite => 'Readable & Writable'; }
```

### Properties

- **Flattened**: `(A & B) & C` normalizes to `A & B & C`
- **Deduplicated**: structurally equal members are collapsed
- **Single-member collapse**: `Intersection(T)` simplifies to `T`

### Subtyping rules

```
T & U <: S     iff  T <: S  OR   U <: S     (any member suffices)
S <: T & U     iff  S <: T  AND  S <: U     (S must subtype all members)
```

### Compound constraints

Intersection syntax also appears in generic constraints, where `+` serves as the intersection operator:

```typist
sub display_max :sig(<T: Num + Show>(T, T) -> Str) ($a, $b) { ... }
```

Here `T` must satisfy both `Num` (type bound) and `Show` (typeclass constraint).

---

## Record Types (Structural)

`{ key => Type, key? => Type }` -- anonymous structural types for hash-shaped data.

```typist
my $p :sig({ name => Str, age => Int }) = { name => "Alice", age => 30 };
```

### Optional fields

Append `?` to the key name to make a field optional:

```typist
BEGIN {
    typedef Config => '{ host => Str, port => Int, tls? => Bool }';
}

my $cfg :sig(Config) = +{ host => "localhost", port => 8080 };          # ok: tls omitted
my $cfg :sig(Config) = +{ host => "localhost", port => 443, tls => 1 }; # ok: tls present
```

When a field is optional, omitting it entirely is valid. But if present, its value must match the declared type.

### Width subtyping

A record with **more fields** is a subtype of a record with **fewer fields**:

```
{ name => Str, age => Int, email => Str }  <:  { name => Str, age => Int }
```

This is width subtyping: having extra information is always safe when the consumer only reads the fields it knows about.

Field types are checked covariantly:

```
{ age => Int }  <:  { age => Num }          # because Int <: Num
```

Optional vs required:

- A required field `k => T` subtypes an optional field `k? => T` (having it is stronger than maybe having it)
- An optional field `k? => T` does NOT subtype a required field `k => T` (it might be absent)

### Records and HashRef

`Record <: HashRef[Str, V]` when all field values are subtypes of `V`. This enables using record literals where a `HashRef` is expected:

```typist
BEGIN { typedef Json => 'Str | Int | Num | Bool | Undef | ArrayRef[Json] | HashRef[Str, Json]'; }

my $data :sig(Json) = +{ name => "Alice", age => 30 };  # record <: HashRef[Str, Json]
```

### typedef with records

Use `typedef` to give a record type a name:

```typist
BEGIN {
    typedef Point  => '{ x => Int, y => Int }';
    typedef Person => '{ name => Str, age => Int }';
}

my $origin :sig(Point) = +{ x => 0, y => 0 };
```

Named records via `typedef` are still structural -- `Point` and `{ x => Int, y => Int }` are interchangeable. For nominal identity, use `struct` instead (see [Structs](struct.md)).

---

## Function Types

`(Params) -> Return` or `(Params) -> Return ![Effects]`

```typist
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
```

### Variance

Function types follow the standard variance rules for subtyping:

| Position | Variance | Rule |
|----------|----------|------|
| Parameters | **Contravariant** | `(A) -> R <: (B) -> R` iff `B <: A` |
| Return type | **Covariant** | `(A) -> R <: (A) -> S` iff `R <: S` |
| Effects | **Covariant** | `-> R ![E1] <: -> R ![E2]` iff `E1 <: E2` |
| Arity | **Strict** | Must match exactly |

Contravariant parameters mean a function that accepts a *wider* type is a subtype of one that accepts a *narrower* type. This is sound because the wider-accepting function can handle everything the narrower-accepting function can, and more.

### CodeRef

`CodeRef[A -> R]` is the parameterized form for function references stored as values:

```typist
my $f :sig(CodeRef[Int -> Str]) = sub ($n) { "$n" };
```

---

## Literal Types

Singleton types that represent exactly one value.

```typist
my $answer :sig(42)               = 42;
my $status :sig("ok" | "error")   = "ok";
```

### Base type hierarchy

Every literal type has a **base type** that it subtypes. The literal is more specific than its base:

```
Literal(42, Int)       <:  Int     <:  Double  <:  Num  <:  Any
Literal(3.14, Double)  <:  Double  <:  Num     <:  Any
Literal("hello", Str)  <:  Str    <:  Any
```

### Static inference

The static analyzer infers literal types from source-level literals:

| Source | Inferred type |
|--------|---------------|
| `42` | `Literal(42, Int)` |
| `3.14` | `Literal(3.14, Double)` |
| `"hello"` | `Literal("hello", Str)` |
| `0` | `Literal(0, Int)` |
| `1` | `Literal(1, Int)` |

### Literal widening

When a literal is assigned to an unannotated variable, the type is **widened** to its base atom for downstream use:

```typist
my $x = 42;       # inferred as Int (widened from Literal(42, Int))
my $s = "hello";  # inferred as Str (widened from Literal("hello", Str))
```

This prevents overly specific types from propagating through the program. With an explicit annotation, the literal type is preserved:

```typist
my $x :sig(42) = 42;   # type is exactly Literal(42, Int), not Int
```

### 0/1 and Bool

By default, `0` and `1` are inferred as `Literal(0, Int)` and `Literal(1, Int)` -- that is, integers, not booleans. Only when the **expected type** is `Bool` (via a `:sig(Bool)` annotation or a function parameter typed as `Bool`) do they become `Bool`:

```typist
my $x :sig(Int)  = 0;    # ok: Literal(0, Int) <: Int
my $b :sig(Bool) = 0;    # ok: bidirectional inference makes it Bool
```

This is bidirectional type inference at work. The expected type flows inward and influences how ambiguous literals are interpreted.

### Literal unions for enumerations

Literal types combine naturally with unions to express enumerations:

```typist
BEGIN {
    typedef Status   => '"ok" | "error" | "pending"';
    typedef SmallInt => '0 | 1 | 2 | 3';
    typedef Toggle   => '0 | 1';
}

my $s :sig(Status) = "ok";       # ok
$s = "pending";                   # ok
# $s = "unknown";                 # type error: not a member
```

---

## Subtype Relationships at a Glance

The complete set of rules governs how types relate to each other:

| Rule | Relation | Condition |
|------|----------|-----------|
| Top | `T <: Any` | Always (for all types T) |
| Bottom | `Never <: T` | Always (for all types T) |
| Atom chain | `Bool <: Int <: Double <: Num <: Any` | Fixed hierarchy |
| Literal promotion | `Literal(v, Base) <: Base` | Always |
| Union sub | `A | B <: S` | `A <: S` and `B <: S` |
| Union super | `S <: A | B` | `S <: A` or `S <: B` |
| Intersection sub | `A & B <: S` | `A <: S` or `B <: S` |
| Intersection super | `S <: A & B` | `S <: A` and `S <: B` |
| Parameterized | `F[A] <: F[B]` | `A <: B` (covariant) |
| Record width | `{ a, b, c } <: { a, b }` | Extra fields OK |
| Record depth | `{ k => A } <: { k => B }` | `A <: B` (covariant) |
| Function params | `(A) -> R <: (B) -> R` | `B <: A` (contravariant) |
| Function return | `(P) -> A <: (P) -> B` | `A <: B` (covariant) |
| Nominal | `Name <: Name` | Identity only (newtype, datatype, struct) |

---

## Next

Now that you know the types, learn how to name them: [typedef and newtype](typedef-newtype.md).
