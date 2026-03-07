# typedef and newtype

Typist provides two mechanisms for naming types: `typedef` for structural aliases and `newtype` for nominal wrappers. They serve different purposes and have different subtyping behavior. Choosing the right one is a fundamental design decision.

---

## typedef -- Structural Aliases

`typedef` creates a named reference to a type expression. The name and the underlying expression are **interchangeable** -- they have the same identity for subtyping purposes.

```typist
BEGIN {
    typedef Name   => 'Str';
    typedef Price  => 'Int';
    typedef Person => '{ name => Str, age => Int }';
    typedef Result => 'Str | Undef';
}
```

### Using typedefs

Once defined, the name works everywhere a type expression does:

```typist
my $name :sig(Name) = "Alice";      # Name = Str, so "Alice" is valid
my $cost :sig(Price) = 1500;        # Price = Int

sub greet :sig((Name) -> Str) ($n) {
    "Hello, $n!";
}

greet("Bob");    # ok: Str <: Name because Name is Str
```

### Structural equivalence

`typedef` creates no barrier. A `Name` is a `Str`, and a `Str` is a `Name`:

```typist
BEGIN {
    typedef Name  => 'Str';
    typedef Label => 'Str';
}

sub greet :sig((Name) -> Str) ($n) { "Hello, $n!" }

greet("Bob");           # ok: Str <: Name
my $label :sig(Label) = "tag";
greet($label);          # ok: Label = Str = Name
```

This is the key property of structural typing: if the shapes match, the types match, regardless of what names are involved.

### Recursive types

Recursion through a type constructor is allowed. The type alias resolves lazily, so the self-reference is productive:

```typist
BEGIN {
    typedef IntList => 'Int | ArrayRef[IntList]';
}

my $list :sig(IntList) = [1, [2, [3, 4]]];   # ok: nested IntList
my $flat :sig(IntList) = 42;                  # ok: Int branch
```

A bare cycle without a constructor is detected and rejected:

```typist
BEGIN {
    typedef A => 'B';
    typedef B => 'A';    # CycleError: A -> B -> A
}
```

### Complex type expressions

`typedef` works with any type expression, including unions, intersections, records, and parameterized types:

```typist
BEGIN {
    typedef Config  => '{ host => Str, port => Int, tls? => Bool }';
    typedef IdOrName => 'Int | Str';
    typedef Matrix   => 'ArrayRef[ArrayRef[Int]]';
    typedef Callback => 'CodeRef[Str -> Void]';

    typedef JsonValue => 'Str | Num | Bool | Undef
                         | ArrayRef[JsonValue]
                         | HashRef[Str, JsonValue]';
}
```

### Composing typedefs

Named types compose naturally -- use one typedef inside another:

```typist
BEGIN {
    typedef Name    => 'Str';
    typedef Age     => 'Int';
    typedef Person  => '{ name => Name, age => Age }';
    typedef People  => 'ArrayRef[Person]';
}

my $team :sig(People) = [
    +{ name => "Alice", age => 30 },
    +{ name => "Bob",   age => 25 },
];
```

Since `Name` is `Str` and `Age` is `Int`, the record `{ name => Name, age => Age }` is structurally identical to `{ name => Str, age => Int }`.

### When to use typedef

- **Readability**: give meaningful names to complex type expressions
- **Abbreviation**: shorten frequently used compound types
- **Documentation**: make signatures self-describing (`Person` vs `{ name => Str, age => Int }`)
- **Recursive types**: self-referential data structures via productive recursion

`typedef` is the right choice when you want **naming** without **distinction**. Two values with the same shape should be interchangeable.

---

## newtype -- Nominal Wrappers

`newtype` creates a **nominal** (name-based) type wrapper. Unlike `typedef`, a newtype is NOT interchangeable with its inner type. Two newtypes wrapping the same inner type are distinct from each other and from the raw type.

```typist
BEGIN {
    newtype UserId  => 'Int';
    newtype OrderId => 'Int';
    newtype Email   => 'Str';
}
```

### Construction and extraction

Each `newtype` generates a constructor function and a `coerce` method:

```typist
my $uid = UserId(42);               # construct: wraps 42 as a UserId
my $raw = UserId::coerce($uid);     # extract: returns 42
```

Values are blessed scalar references (`Typist::Newtype::UserId`). The constructor validates that the inner value matches the declared type.

### Nominal identity

`UserId` is NOT a subtype of `Int`, even though it wraps `Int`:

```typist
my $uid :sig(UserId) = UserId(42);

# All of these are type errors:
# $uid = 42;              # raw Int is not UserId
# $uid = OrderId(42);     # OrderId is not UserId
```

Only `UserId` values satisfy the `UserId` type. This is the fundamental guarantee of nominal typing.

```
UserId  <: UserId       # ok: nominal identity
UserId </: Int          # no: nominal barrier
Int    </: UserId       # no: nominal barrier
UserId </: OrderId      # no: different names
```

### Newtypes in function signatures

Functions that accept `UserId` will reject `OrderId`, raw `Int`, and everything else:

```typist
sub find_user :sig((UserId) -> Str) ($id) {
    "User #" . UserId::coerce($id);
}

find_user(UserId(42));       # ok
# find_user(OrderId(42));    # type error: OrderId is not UserId
# find_user(42);             # type error: Int is not UserId
```

### Constructor validation

The constructor validates the inner value's type. With `-runtime` enabled, this validation is enforced at construction time:

```typist
use Typist -runtime;

my $uid = UserId(42);        # ok: 42 is Int
eval { UserId("hello") };    # dies: "hello" is not Int
eval { Email(42) };          # dies: 42 is not Str
```

Without `-runtime`, structural checks (arity) remain active but type validation is skipped.

### Combining newtypes with other types

Newtypes work naturally in records, structs, and compound types:

```typist
BEGIN {
    newtype UserId => 'Int';
    newtype Email  => 'Str';
    typedef Account => '{ id => UserId, email => Email, name => Str }';
}

my $acct :sig(Account) = +{
    id    => UserId(1),
    email => Email('alice@example.com'),
    name  => "Alice",
};
```

Here `id` must be a `UserId` (not a raw `Int`) and `email` must be an `Email` (not a raw `Str`). The nominal barrier propagates through the type structure.

### When to use newtype

- **Domain safety**: prevent accidental mixing of semantically different values (`UserId` vs `OrderId`)
- **API boundaries**: enforce that callers construct values through the proper constructor
- **Type-driven design**: make invalid states unrepresentable at the type level

`newtype` is the right choice when two values with the same *representation* should NOT be *interchangeable*.

---

## typedef vs newtype

| | typedef | newtype |
|---|---|---|
| Identity | Structural (interchangeable) | Nominal (distinct) |
| Subtyping | `Name <: InnerType` and `InnerType <: Name` | `Name </: InnerType` |
| Values | Plain Perl values | Blessed scalar references |
| Construction | N/A (transparent) | `Name($value)` |
| Extraction | N/A (transparent) | `Name::coerce($value)` |
| Use case | Readability, abbreviation, recursion | Domain safety, preventing mix-ups |
| Runtime cost | Zero | Blessed scalar ref allocation |

### A practical example

Consider a function that transfers money between accounts:

```typist
# With typedef -- DANGEROUS
BEGIN {
    typedef AccountId => 'Int';
    typedef Amount    => 'Int';
}

sub transfer :sig((AccountId, AccountId, Amount) -> Void) ($from, $to, $amt) {
    # $from, $to, and $amt are all just Int
    # Nothing prevents: transfer($amount, $from_id, $to_id)
}

transfer(100, 1, 2);   # Compiles fine but is semantically wrong!
```

```typist
# With newtype -- SAFE
BEGIN {
    newtype AccountId => 'Int';
    newtype Amount    => 'Int';
}

sub transfer :sig((AccountId, AccountId, Amount) -> Void) ($from, $to, $amt) {
    # $from and $to must be AccountId, $amt must be Amount
}

transfer(AccountId(1), AccountId(2), Amount(100));   # Correct
# transfer(Amount(100), AccountId(1), AccountId(2)); # TYPE ERROR
```

The newtype version makes the argument order part of the type contract. The compiler catches the mistake before it reaches production.

---

## BEGIN blocks

Both `typedef` and `newtype` must appear inside `BEGIN` blocks so that the type definitions are available during CHECK-phase static analysis:

```typist
# Correct
BEGIN {
    typedef Name => 'Str';
    newtype UserId => 'Int';
}

# Wrong -- not visible during CHECK phase
typedef Name => 'Str';
newtype UserId => 'Int';
```

Multiple definitions can share a single `BEGIN` block, or each can have its own. The only requirement is that the definition executes at compile time.

---

## Next

For immutable, blessed, nominal record types with field accessors, see [Structs](struct.md).
