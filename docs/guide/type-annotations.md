# Type Annotations

Typist uses a single annotation syntax for everything: the `:sig()` attribute. It works on variables and functions, and it encodes parameter types, return types, generic bounds, typeclass constraints, effects, and variadic signatures -- all in one unified notation.

---

## Variables

Attach `:sig(Type)` to a `my` declaration to annotate a variable's type.

```typist
my $count :sig(Int)       = 0;
my $label :sig(Str)       = "hello";
my $ratio :sig(Double)    = 3.14;
my $flag  :sig(Bool)      = 1;
```

Compound types work the same way:

```typist
my $maybe :sig(Maybe[Str])              = undef;
my $nums  :sig(ArrayRef[Int])           = [1, 2, 3];
my $map   :sig(HashRef[Str, Int])       = +{ a => 1, b => 2 };
my $pair  :sig(Tuple[Str, Int])         = ["Alice", 30];
my $data  :sig({ name => Str, age => Int }) = { name => "A", age => 1 };
```

Union and intersection types:

```typist
my $id     :sig(Int | Str)  = 42;
my $status :sig("ok" | "error") = "ok";
```

Variables declared without `:sig()` are not unchecked -- Typist still infers their type from the initializer expression (flow typing). The annotation makes the type *explicit* and enforces it on reassignment in runtime mode.

---

## Functions

Function annotations go **between the subroutine name and the parameter list**:

```typist
sub name :sig(annotation) ($params) { body }
```

This placement is required by Perl's attribute syntax. The `:sig()` attribute is parsed before the subroutine body is compiled.

### Basic functions

```typist
sub add :sig((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

sub greet :sig((Str) -> Str) ($name) {
    "Hello, $name!";
}

sub is_positive :sig((Int) -> Bool) ($n) {
    $n > 0;
}
```

### Functions with effects

Effects are declared after the return type with `![ ]`:

```typist
sub greet :sig((Str) -> Void ![Console]) ($name) {
    Console::writeLine("Hello, $name!");
}

sub fetch_and_log :sig((Str) -> Any ![DB, Console]) ($query) {
    my $result = DB::query($query);
    Console::writeLine("fetched: $result");
    $result;
}
```

### Generic functions

Type parameters go in `<>` before the parameter list:

```typist
sub identity :sig(<T>(T) -> T) ($x) {
    $x;
}

sub first :sig(<T>(ArrayRef[T]) -> T) ($arr) {
    $arr->[0];
}

sub pair :sig(<T, U>(T, U) -> Tuple[T, U]) ($a, $b) {
    [$a, $b];
}
```

### Bounded generics

Constrain a type parameter with an upper bound using `T: Bound`:

```typist
sub max_of :sig(<T: Num>(T, T) -> T) ($a, $b) {
    $a > $b ? $a : $b;
}
```

Here `T` must be a subtype of `Num`, so calling `max_of("a", "b")` is a type error.

### Typeclass constraints

When the bound name is a registered typeclass rather than a type, it becomes a typeclass constraint:

```typist
sub show_it :sig(<T: Show>(T) -> Str) ($x) {
    Show::show($x);
}
```

The static checker verifies that the inferred type argument has a registered `Show` instance.

### Compound constraints

Combine multiple typeclass constraints with `+`:

```typist
sub display_max :sig(<T: Num + Show>(T, T) -> Str) ($a, $b) {
    Show::show($a > $b ? $a : $b);
}
```

Both `Num` (type bound) and `Show` (typeclass constraint) are checked independently. The parser disambiguates by consulting the Registry: names that match a registered typeclass become typeclass constraints; everything else is a type bound.

### Variadic functions

Use `...Type` for a rest parameter:

```typist
sub log_all :sig((Str, ...Any) -> Void) ($fmt, @args) {
    say sprintf($fmt, @args);
}
```

The minimum arity is determined by the fixed parameters. `log_all("hello")` is valid (zero variadic args); `log_all()` is an arity error.

### Default parameters

Default values in the Perl signature reduce the minimum arity:

```typist
sub connect :sig((Str, Int) -> Void) ($host, $port = 8080) {
    # $port defaults to 8080 if omitted
}

connect("localhost", 3000);   # ok: 2 args
connect("localhost");         # ok: 1 arg (port defaults)
```

The type annotation declares the full parameter list. The static checker counts defaults to determine the minimum number of required arguments.

### Generic functions with effects

All pieces compose:

```typist
sub logged_first :sig(<T>(ArrayRef[T]) -> T ![Console]) ($arr) {
    Console::writeLine("taking first element");
    $arr->[0];
}
```

---

## Pattern Summary

| Pattern | Syntax | Example |
|---------|--------|---------|
| Variable | `:sig(Type)` | `my $x :sig(Int) = 0` |
| Function | `:sig((Params) -> Return)` | `sub f :sig((Int) -> Str) ($n) { }` |
| Effects | `![E1, E2]` | `:sig((Str) -> Void ![Console])` |
| Generics | `<T>`, `<T, U>` | `:sig(<T>(T) -> T)` |
| Bounded | `<T: Bound>` | `:sig(<T: Num>(T) -> T)` |
| Typeclass | `<T: TC>` | `:sig(<T: Show>(T) -> Str)` |
| Compound | `<T: A + B>` | `:sig(<T: Num + Show>(T, T) -> Str)` |
| Variadic | `...Type` | `:sig((Str, ...Any) -> Void)` |

---

## Important Notes

### Placement

The `:sig()` attribute must appear between the function name and the parameter signature. This is not a style choice -- it is dictated by Perl's attribute grammar:

```typist
# Correct
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }

# Wrong -- attribute cannot follow the parameter list
sub add ($a, $b) :sig((Int, Int) -> Int) { $a + $b }
```

### No imports needed for type names

Type names inside `:sig()` are resolved via the Typist Registry. You do not need to import `Int`, `Str`, or any user-defined type name. As long as the type is registered (via `typedef`, `newtype`, `struct`, `datatype`, etc. in a `BEGIN` block, or via the Prelude), it is available in annotations:

```typist
use Typist;

BEGIN {
    typedef Name => 'Str';
    newtype UserId => 'Int';
}

# Both Name and UserId resolve without any additional import
sub find_user :sig((UserId) -> Name) ($id) { ... }
```

### Flow typing for unannotated variables

Variables without `:sig()` are not ignored. Typist infers their type from the initializer expression:

```typist
my $x = 42;        # inferred as Int (widened from Literal(42, Int))
my $s = "hello";   # inferred as Str
my $a = [1, 2, 3]; # inferred as ArrayRef[Int]
```

The inferred type is used for downstream type checking (e.g., passing `$x` to a function that expects `Str` produces a diagnostic). The difference from an explicit `:sig()` annotation is that inferred types are not enforced on reassignment in runtime mode.

### Effect syntax

The `!` before the bracket is part of the effect syntax, not a negation. It reads as "may perform these effects":

```typist
:sig((Str) -> Void ![Console])
#                  ^^^^^^^^^^ effect annotation
```

Multiple effects are comma-separated inside the brackets:

```typist
:sig((Str) -> Any ![DB, Console, Exn])
```

A function with no `![ ]` clause is treated as pure (no effects). See [Algebraic Effects](effects.md) for the full effect system.

### Method-style annotations and `$self`

`:sig()` can annotate methods on blessed-hashref classes. The parameter list in the annotation describes only the **caller-visible arguments** -- `$self` and `$class` are excluded:

```typist
package Cart;

sub new :sig((CustomerId) -> Any) ($class, $customer_id) {
    bless { customer_id => $customer_id, items => [] }, $class;
}

sub item_count :sig(() -> Int) ($self) { scalar @{$self->{items}} }
sub total      :sig(() -> Price) ($self) { $self->{_total} }
```

These annotations are valid and register correctly in the Registry. However, there is an important limitation for **static analysis**:

The static analyzer resolves `->` accessor chains by examining the receiver's type. For Typist Structs (`struct Point => (...)`) the analyzer knows the type and its fields, so `$p->x` resolves to `Int`. For blessed-hashref objects, the receiver (`$self`) is typed as `Any`, so method return types **cannot be inferred** through the call chain:

```typist
my $cart = Cart->new(CustomerId(1));
$cart->total;   # analyzer sees Any->total — cannot resolve to Price
```

If you need the static analyzer to track `->` accessor types, use Typist Structs. For traditional Perl OO classes, use qualified function calls (`Cart::total($self)`) or bind method results to typed locals:

```typist
my $t :sig(Price) = $cart->total;   # explicit annotation restores type info
```

### String-based declarations

All type declarations use strings for their type expressions:

```typist
BEGIN {
    typedef Name   => 'Str';               # string
    newtype UserId => 'Int';               # string
    struct Person  => (name => 'Str', age => 'Int');  # strings
}
```

This is because type expressions are parsed by Typist's own parser, not by Perl. Using strings avoids conflicts with Perl's syntax (barewords, operators, etc.).
