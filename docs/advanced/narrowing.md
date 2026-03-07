# Type Narrowing

Type narrowing refines a variable's type within a specific code block based on control-flow guards. When you check whether a value is `defined`, test its type with `isa`, or inspect its `ref`, Typist uses that information to give the variable a more precise type inside the guarded block. This eliminates false-positive diagnostics when working with union types and optional values.

---

## How Narrowing Works

Without narrowing, a union type like `Str | Undef` forces the checker to consider both possibilities everywhere. With narrowing, a guard like `defined($x)` splits the analysis: inside the `if` block, `$x` is `Str`; inside the `else` block, `$x` is `Undef`.

The narrowing engine operates during static analysis (Phase 3 of the Analyzer pipeline). It examines the condition of `if`/`unless`/`elsif` statements and produces a refined type environment for each branch.

---

## Supported Guards

### 1. `defined()` -- Remove Undef

The most common narrowing pattern. When a variable has a union type that includes `Undef`, a `defined()` check removes the `Undef` member:

```perl
sub process :sig((Str | Undef) -> Str) ($x) {
    if (defined($x)) {
        # $x is narrowed to Str here.
        # No TypeMismatch on returning a Str.
        return "got: $x";
    } else {
        # $x is Undef here (inverse narrowing).
        return "nothing";
    }
}
```

Both `defined($x)` (with parentheses) and `defined $x` (without) are recognized.

### 2. Truthiness -- Remove Undef from Unions

A bare variable in a condition narrows by removing `Undef` from its union type:

```perl
my $name :sig(Str | Undef) = get_name();
if ($name) {
    # $name is narrowed to Str.
    say "Hello, $name";
}
```

Truthiness narrowing is more conservative than `defined()` -- it only applies when the condition is a single bare variable. Complex expressions like `$x && $y` or `length($x)` are not recognized.

### 3. `isa` -- Narrow to a Specific Type

Perl's `isa` operator narrows a variable to the tested type:

```perl
BEGIN {
    struct Person => (name => 'Str');
    struct Animal => (species => 'Str');
}

sub describe :sig((Person | Animal) -> Str) ($entity) {
    if ($entity isa Person) {
        # $entity is narrowed to Person.
        return "Person: " . $entity->name;
    } else {
        # $entity is narrowed to Animal (Person subtracted from the union).
        return "Animal: " . $entity->species;
    }
}
```

The `isa` guard resolves type names through the Registry. Fully qualified names like `Typist::Struct::Person` are also recognized and resolved to their short form.

### 4. `ref()` -- Narrow by Reference Type

The `ref()` function with a string comparison narrows a variable to the corresponding Typist type:

```perl
sub process_data :sig((ArrayRef[Int] | HashRef[Str, Int]) -> Str) ($data) {
    if (ref($data) eq 'ARRAY') {
        # $data is narrowed to ArrayRef[Any].
        return "array with " . scalar(@$data) . " elements";
    }
    if (ref($data) eq 'HASH') {
        # $data is narrowed to HashRef[Any].
        return "hash with " . scalar(keys %$data) . " keys";
    }
    "unknown";
}
```

The ref-to-type mapping:

| `ref()` string | Narrowed type |
|----------------|---------------|
| `ARRAY` | `ArrayRef[Any]` |
| `HASH` | `HashRef[Any]` |
| `SCALAR` | `Ref[Any]` |
| `CODE` | `Ref[Any]` |
| `REF` | `Ref[Any]` |
| `Regexp` | `Ref[Any]` |
| `GLOB` | `Ref[Any]` |
| `IO` | `Ref[Any]` |
| `VSTRING` | `Str` |

Blessed class names (e.g., `ref($x) eq 'Point'`) are resolved through the Registry as struct/type names.

Both `ref($x)` and `ref $x` (with or without parentheses) are recognized. Both `eq` and `ne` operators are supported -- `ne` reverses the narrowing polarity.

### 5. Early Return -- Narrow for the Remainder

A `return ... unless defined($x)` pattern narrows `$x` for all subsequent statements in the function body:

```perl
sub greet :sig((Maybe[Str]) -> Str) ($name) {
    return "stranger" unless defined($name);
    # From here on, $name is narrowed to Str.
    "Hello, $name!";
}
```

This is the guard-clause pattern common in Perl. The narrowing engine scans preceding sibling statements for early-return guards and accumulates their narrowing effects.

Multiple early returns compose:

```perl
sub process :sig((Maybe[Str], Maybe[Int]) -> Str) ($name, $age) {
    return "no name" unless defined($name);
    return "no age"  unless defined($age);
    # Both $name (Str) and $age (Int) are narrowed here.
    "$name is $age years old";
}
```

---

## Accessor Chain Narrowing

Narrowing extends to struct field accessors. When you check `defined($struct->field)` for an optional field, the accessor's type is narrowed inside the guarded block:

```perl
BEGIN {
    struct Config => (
        host => 'Str',
        optional(port => 'Int'),
        optional(name => 'Str'),
    );
}

sub describe_config :sig((Config) -> Str) ($c) {
    if (defined($c->name)) {
        # $c->name is narrowed from Str | Undef to Str.
        return "Config for " . $c->name;
    }
    "anonymous config";
}
```

Accessor chain narrowing also works with early returns:

```perl
sub config_label :sig((Config) -> Str) ($c) {
    return "unnamed" unless defined($c->name);
    # $c->name is Str for the rest of the function.
    $c->name;
}
```

Multi-level accessor chains (e.g., `$a->b->c`) are parsed but only single-level chains (`$a->b`) currently participate in narrowing.

---

## `unless` Polarity

`unless` reverses the narrowing polarity relative to `if`. The body of `unless` receives the *inverse* narrowing:

```perl
my $x :sig(Str | Undef) = get_value();
unless (defined($x)) {
    # $x is Undef here (the inverse of defined).
}
# The else-block of unless (if any) would see $x as Str.
```

This applies to all narrowing guards, not just `defined`.

---

## Inverse Narrowing in Else Blocks

For `if` statements with `else` blocks, the else branch receives the inverse of the narrowing:

| Guard | Then-block (if) | Else-block |
|-------|-----------------|------------|
| `defined($x)` | Undef removed | `$x` is `Undef` |
| `$x isa Person` | `$x` is `Person` | `Person` subtracted from union |
| `ref($x) eq 'HASH'` | `$x` is `HashRef[Any]` | Matching type subtracted from union |
| `$x` (truthiness) | Undef removed | No inverse narrowing |
| `ref($x) ne 'HASH'` | Matching type subtracted | `$x` is `HashRef[Any]` |

For `isa` and `ref` guards, inverse narrowing subtracts the matched type from the original union. If the variable is not a union type, no inverse narrowing is applied.

---

## Narrowing and the LSP

Narrowed types are recorded by the narrowing engine and surfaced in the LSP server:

- **Hover**: Hovering over a variable inside a narrowed block shows its refined type, not the original declared type.
- **Inlay hints**: Narrowed types are displayed via `_display_type` with the correct sigil-matched representation.
- **Diagnostics**: Type checks inside narrowed blocks use the refined environment, so `TypeMismatch` errors account for narrowing.

---

## Limitations

- **Only `eq`/`ne` with string literals or literal-typed variables** are recognized for `ref()` narrowing. Variable comparisons with non-literal types are skipped (gradual: no error, no narrowing).
- **Complex boolean conditions** (`$x && defined($y)`, `!defined($x)`) are not decomposed. Only single-guard conditions are analyzed.
- **Narrowing does not propagate through function calls.** If you pass a union-typed variable to a function that checks `defined` internally, the caller's type is not narrowed.
- **Multi-level accessor chains** (`$a->b->c`) are parsed but only single-level chains (`$a->field`) participate in narrowing.
- **`elsif` branches**: Each `elsif` is treated as an independent condition. Cumulative narrowing from prior rejected branches is not tracked.
