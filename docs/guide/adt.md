# ADTs and Pattern Matching

Algebraic data types (ADTs) let you define tagged unions -- types where a value is one of several named variants, each carrying its own typed payload. Combined with `match` for pattern dispatching, they provide a structured alternative to ad-hoc flag checking and polymorphic dispatch.

---

## datatype -- Tagged Unions

Use `datatype` inside a `BEGIN` block to define a sum type:

```typist
use v5.40;
use Typist;

BEGIN {
    datatype Shape =>
        Circle    => '(Int)',
        Rectangle => '(Int, Int)',
        Point     => '()';
}
```

This creates:

- A type named `Shape` registered in the Typist Registry
- Constructor functions `Circle(...)`, `Rectangle(...)`, and `Point()` installed in the calling namespace
- All values are blessed into `Typist::Data::Shape`

### Variant Specification Syntax

Each variant's type spec is a string of comma-separated types in parentheses:

| Spec | Meaning |
|------|---------|
| `'(Int)'` | One argument of type `Int` |
| `'(Int, Str)'` | Two arguments: `Int` and `Str` |
| `'()'` | No arguments (nullary constructor) |
| `''` | Also no arguments (empty string is equivalent to `'()'`) |

### Constructing Values

```typist
my $c = Circle(5);
my $r = Rectangle(3, 4);
my $p = Point();
```

Each constructed value is a blessed hashref with two internal fields:

- `_tag` -- the variant name (e.g., `"Circle"`)
- `_values` -- an arrayref of the constructor arguments (e.g., `[5]`)

### Structural Enforcement (Always Active)

Arity is always checked, regardless of runtime mode:

```typist
eval { Circle(1, 2) };
# Dies: Circle(): expected 1 arguments, got 2

eval { Rectangle(3) };
# Dies: Rectangle(): expected 2 arguments, got 1
```

### Type Validation (Runtime Mode Only)

With `use Typist -runtime`, each argument is checked against its declared type:

```typist
use Typist -runtime;

eval { Circle("big") };
# Dies: Circle(): argument 1 expected Int, got big
```

---

## Parameterized ADTs

ADTs can be generic. Quote the name when it has type parameters:

```typist
BEGIN {
    datatype 'Option[T]' =>
        Some => '(T)',
        None => '()';

    datatype 'Result[T]' =>
        Ok  => '(T)',
        Err => '(Str)';

    datatype 'Either[L, R]' =>
        Left  => '(L)',
        Right => '(R)';
}
```

### Construction and Type Inference

Type arguments are inferred from the constructor arguments at runtime (with `-runtime`) or statically at the call site:

```typist
my $x = Some(42);          # Option[Int]
my $y = Some("hello");     # Option[Str]
my $n = None();            # Option[?] (no inference possible)

my $ok  = Ok("success");   # Result[Str]
my $err = Err("failure");  # Result[Str]

my $left  = Left("error");   # Either[Str, ?]
my $right = Right(200);      # Either[?, Int]
```

For nullary constructors like `None()`, no type argument can be inferred from the arguments. The type argument remains unbound until constrained by context (e.g., a function annotation).

### Multi-Parameter ADTs

Multiple type parameters work independently:

```typist
BEGIN {
    datatype 'Either[L, R]' =>
        Left  => '(L)',
        Right => '(R)';
}

my $ok  = Right(200);
my $err = Left("not found");
```

---

## GADT -- Per-Constructor Return Types

Generalized algebraic data types (GADTs) extend plain ADTs by letting each constructor specify its own return type. This constrains the type parameter to a specific type per variant:

```typist
BEGIN {
    datatype 'Expr[A]' =>
        IntLit  => '(Int) -> Expr[Int]',
        BoolLit => '(Bool) -> Expr[Bool]',
        Add     => '(Expr[Int], Expr[Int]) -> Expr[Int]',
        IfThen  => '(Expr[Bool], Expr[A], Expr[A]) -> Expr[A]';
}
```

The `->` in the variant specification forces the type argument. Without it, type arguments are inferred from the constructor arguments; with it, the declared return type overrides inference:

```typist
my $lit = IntLit(42);
# $lit->{_type_args}[0] is Int (forced by -> Expr[Int])

my $b = BoolLit(1);
# $b->{_type_args}[0] is Bool (forced by -> Expr[Bool])

my $sum = Add(IntLit(1), IntLit(2));
# $sum->{_type_args}[0] is Int
```

GADTs are useful for building type-safe interpreters, expression trees, and similar structures where different variants carry different type guarantees.

---

## enum -- Nullary ADT Sugar

When all variants take zero arguments, use `enum` for concise syntax:

```typist
BEGIN {
    enum Color     => qw(Red Green Blue);
    enum Direction => qw(North South East West);
}
```

This is equivalent to:

```typist
BEGIN {
    datatype Color =>
        Red   => '()',
        Green => '()',
        Blue  => '()';
}
```

### Using Enums

Enum constructors take no arguments. Call them with empty parens:

```typist
my $c = Red();
my $d = North();
```

Enum values carry a `_tag` but no `_values` payload (empty arrayref).

---

## match -- Pattern Matching

`match` dispatches on the `_tag` of an ADT value and passes the `_values` as arguments to the matching handler:

```typist
my $area = match $shape,
    Circle    => sub ($r)      { 3.14159 * $r ** 2 },
    Rectangle => sub ($w, $h)  { $w * $h },
    Point     => sub           { 0 };
```

### Syntax

```typist
match $value,
    Tag1 => sub (...) { ... },
    Tag2 => sub (...) { ... },
    ...;
```

`match` is a function call (not a keyword). The first argument is the ADT value; the remaining arguments are `tag => handler` pairs.

### How It Works

1. Reads `$value->{_tag}` to identify the variant
2. Looks up the handler for that tag
3. Splats `$value->{_values}->@*` as arguments to the handler
4. Returns the handler's return value

### The `_` Fallback Arm

Use `_` as a catch-all for unmatched variants:

```typist
sub describe ($shape) {
    match $shape,
        Circle => sub ($r) { "circle with radius $r" },
        _      => sub      { "some other shape" };
}
```

### Missing Arms

If no handler matches and there is no `_` fallback, `match` dies at runtime:

```typist
eval {
    match Rectangle(3, 4),
        Circle => sub ($r) { $r };
};
# Dies: Typist: match — no arm for tag 'Rectangle' and no fallback '_'
```

### Exhaustiveness Checking

Exhaustiveness is **not** checked at runtime (beyond the die-on-missing-arm behavior above). Instead, it is checked by:

- **The static analyzer (LSP)** -- produces a diagnostic when a `match` expression is missing arms for known variants
- **Perl::Critic policy** -- the `MatchExhaustiveness` policy reports incomplete `match` expressions

This design keeps runtime `match` fast while catching missing arms during development.

### Return Value

`match` returns the result of the matched handler. It works in both scalar and list context:

```typist
my $area = match $shape,
    Circle    => sub ($r)     { 3.14 * $r ** 2 },
    Rectangle => sub ($w, $h) { $w * $h },
    Point     => sub          { 0 };

say "Area: $area";
```

---

## match with Typed Functions

Combine `match` with `:sig()` annotations for fully typed pattern matching:

```typist
sub describe_result :sig((Result[Str]) -> Str) ($res) {
    match $res,
        Ok  => sub ($val) { "Success: $val" },
        Err => sub ($msg) { "Error: $msg" };
}

sub color_name :sig((Color) -> Str) ($c) {
    match $c,
        Red   => sub { "red" },
        Green => sub { "green" },
        Blue  => sub { "blue" };
}
```

The static analyzer checks that:

- The match arms cover all variants (exhaustiveness)
- Handler argument counts match variant arities
- Return types are consistent with the function signature

---

## Recursive ADTs

ADT variants can reference the ADT's own type, enabling recursive data structures:

```typist
BEGIN {
    datatype Expr =>
        Lit => '(Int)',
        Add => '(Expr, Expr)',
        Mul => '(Expr, Expr)';
}

# 2 + 3 * 4
my $expr = Add(Lit(2), Mul(Lit(3), Lit(4)));

sub eval_expr ($e) {
    match $e,
        Lit => sub ($n)     { $n },
        Add => sub ($l, $r) { eval_expr($l) + eval_expr($r) },
        Mul => sub ($l, $r) { eval_expr($l) * eval_expr($r) };
}

say eval_expr($expr);   # 14
```

---

## ADT Internals

For users who need to inspect ADT values directly (e.g., for serialization):

| Field | Type | Description |
|-------|------|-------------|
| `_tag` | `Str` | The variant name |
| `_values` | `ArrayRef` | Constructor arguments as a list |
| `_type_args` | `ArrayRef[Type]` | Inferred or forced type arguments (parameterized ADTs only, `-runtime` only) |

Values are blessed into `Typist::Data::$TypeName` (e.g., `Typist::Data::Shape`). All variants of the same datatype share the same blessed class.

---

## Complete Example

```typist
use v5.40;
use Typist;

BEGIN {
    # Simple ADT
    datatype Shape =>
        Circle    => '(Int)',
        Rectangle => '(Int, Int)',
        Point     => '()';

    # Parameterized ADT
    datatype 'Option[T]' =>
        Some => '(T)',
        None => '()';

    # Enum (nullary sugar)
    enum Priority => qw(Low Medium High);
}

# Construction
my $circle = Circle(5);
my $rect   = Rectangle(3, 4);
my $x      = Some(42);
my $n      = None();
my $pri    = High();

# Pattern matching
sub area :sig((Shape) -> Num) ($s) {
    match $s,
        Circle    => sub ($r)     { 3.14159 * $r ** 2 },
        Rectangle => sub ($w, $h) { $w * $h },
        Point     => sub          { 0 };
}

sub unwrap_or :sig(<T>(Option[T], T) -> T) ($opt, $default) {
    match $opt,
        Some => sub ($v) { $v },
        None => sub      { $default };
}

say area(Circle(10));              # 314.159
say area(Rectangle(3, 4));        # 12
say unwrap_or(Some(42), 0);       # 42
say unwrap_or(None(), 0);         # 0

sub priority_label :sig((Priority) -> Str) ($p) {
    match $p,
        Low    => sub { "low" },
        Medium => sub { "medium" },
        High   => sub { "high" };
}

say priority_label(High());       # "high"
```

---

## Next

- [Generics](generics.md) -- parametric polymorphism with bounded quantification and type inference
