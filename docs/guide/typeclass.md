# Type Classes

Type classes provide ad-hoc polymorphism -- the ability to define an interface once and implement it differently for each type. Unlike generics (which provide uniform behavior over all types), type classes let each type supply its own specialized implementation.

If you are familiar with Haskell type classes, Rust traits, or Swift protocols, Typist's type classes serve the same role.

---

## Defining a Type Class

Use `typeclass` inside a `BEGIN` block:

```typist
use v5.40;
use Typist;

BEGIN {
    typeclass Show => 'T', +{
        show => '(T) -> Str',
    };
}
```

The three arguments are:

1. **Class name** -- `Show`
2. **Type variable specification** -- `'T'` (a string; the variable that instances will substitute)
3. **Method signatures** -- a hashref of method name to signature string

This registers the typeclass in the Typist Registry and creates a **synthetic namespace** `Show::` with a dispatch function `Show::show(...)`.

### Multiple Methods

A typeclass can declare any number of methods:

```typist
BEGIN {
    typeclass Eq => 'T', +{
        eq  => '(T, T) -> Bool',
        neq => '(T, T) -> Bool',
    };
}
```

All methods must be provided when defining an instance.

---

## Implementing Instances

Use `instance` to provide concrete implementations for a specific type:

```typist
BEGIN {
    instance Show => 'Int', +{
        show => sub ($v) { "$v" },
    };

    instance Show => 'Str', +{
        show => sub ($v) { qq["$v"] },
    };

    instance Show => 'Bool', +{
        show => sub ($v) { $v ? "True" : "False" },
    };
}
```

The three arguments are:

1. **Class name** -- must match a registered typeclass
2. **Type expression** -- the type this instance covers (as a string)
3. **Method implementations** -- a hashref of method name to subroutine reference

### Completeness Check

Every method declared in the typeclass must be provided. Missing a method dies immediately:

```typist
eval {
    instance Eq => 'Int', +{
        eq => sub ($a, $b) { $a == $b ? 1 : 0 },
        # neq is missing!
    };
};
# Dies: Typist: instance Eq for Int missing method 'neq'
```

### Instance for User-Defined Types

Instances work with any type -- including structs, newtypes, and ADTs:

```typist
BEGIN {
    struct Point => (x => 'Int', y => 'Int');

    instance Show => 'Point', +{
        show => sub ($p) { "Point(" . $p->x . ", " . $p->y . ")" },
    };
}

say Show::show(Point(x => 1, y => 2));   # "Point(1, 2)"
```

---

## Using Type Class Methods

Call methods through the synthetic namespace `ClassName::method_name`:

```typist
say Show::show(42);         # "42"
say Show::show("hello");    # "\"hello\""
say Show::show(1);          # "1" (dispatched as Int)

say Eq::eq(1, 1);           # 1
say Eq::neq("a", "b");     # 1
```

### Dispatch Resolution

When you call `Show::show($value)`, the dispatch function:

1. Infers the runtime type of `$value` via `Typist::Inference->infer_value()`
2. Looks up the matching instance in the Registry (exact match first, then subtype scan)
3. Calls the instance's implementation with the original arguments

If no matching instance is found, it dies:

```typist
eval { Show::show([1, 2, 3]) };
# Dies: Typist: no instance of Show for ArrayRef
```

---

## Superclass Constraints

A typeclass can require that instances also have instances of other typeclasses:

```typist
BEGIN {
    typeclass Ord => 'T: Eq', +{
        compare => '(T, T) -> Int',
    };
}
```

`T: Eq` means: to define an `Ord` instance for a type, that type must already have an `Eq` instance. The superclass constraint is checked when the instance is registered:

```typist
BEGIN {
    # This works because Eq for Int is already registered above
    instance Ord => 'Int', +{
        compare => sub ($a, $b) { $a <=> $b },
    };

    # This would die if Eq for Str were not registered
    instance Ord => 'Str', +{
        compare => sub ($a, $b) { $a cmp $b },
    };
}
```

If the superclass instance is missing:

```typist
eval {
    instance Ord => 'Double', +{
        compare => sub ($a, $b) { $a <=> $b },
    };
};
# Dies: Typist: instance Ord for Double requires superclass instance Eq for Double
```

---

## Multi-Parameter Type Classes

Typeclasses can have multiple type variables:

```typist
BEGIN {
    typeclass Convertible => 'T, U', +{
        convert => '(T) -> U',
    };

    instance Convertible => 'Int, Str', +{
        convert => sub ($x) { "$x" },
    };

    instance Convertible => 'Str, Int', +{
        convert => sub ($s) { int($s) },
    };
}
```

### Instance Resolution for Multi-Parameter Classes

For single-parameter classes, dispatch resolves from the first argument's type. For multi-parameter classes, dispatch infers types from multiple arguments (up to the number of type parameters) and matches against registered instances:

```typist
say Convertible::convert(42);      # "42" (matches Int, Str instance)
```

The multi-parameter type expression in the instance declaration uses comma separation: `'Int, Str'` means `T = Int, U = Str`.

---

## Higher-Kinded Types

Type classes can abstract over type constructors (types of kind `* -> *`) rather than concrete types:

```typist
BEGIN {
    typeclass Functor => 'F: * -> *', +{
        fmap => '(F[A], CodeRef[A -> B]) -> F[B]',
    };

    instance Functor => 'ArrayRef', +{
        fmap => sub ($arr, $f) { [map { $f->($_) } @$arr] },
    };
}
```

`F: * -> *` declares `F` as a type constructor that takes one type argument. The instance for `ArrayRef` (a `* -> *` constructor) provides a concrete implementation:

```typist
my $doubled = Functor::fmap([1, 2, 3], sub ($x) { $x * 2 });
say "@$doubled";   # 2 4 6

my $strings = Functor::fmap([10, 20], sub ($x) { "[$x]" });
say "@$strings";   # [10] [20]
```

Instance resolution for HKT classes matches by constructor name: `ArrayRef[Int]` matches the `ArrayRef` instance because `ArrayRef` is the type constructor.

---

## Type Class Constraints in Signatures

Use `T: ClassName` in a function's generic declaration to require a typeclass instance:

```typist
sub print_value :sig(<T: Show>(T) -> Void ![IO]) ($x) {
    say Show::show($x);
}
```

The static analyzer checks at each call site that the inferred type argument has a registered instance of the specified typeclass. This catches errors before runtime:

```typist
print_value(42);         # ok: Show instance for Int exists
print_value("hello");    # ok: Show instance for Str exists
print_value([1, 2, 3]);  # diagnostic: no instance of Show for ArrayRef[Int]
```

### Compound Constraints

Combine typeclass constraints with `+`:

```typist
sub sorted_display :sig(<T: Ord + Show>(ArrayRef[T]) -> Str) ($arr) {
    my @sorted = sort { Ord::compare($a, $b) } @$arr;
    join(", ", map { Show::show($_) } @sorted);
}
```

`T` must have both `Ord` and `Show` instances.

---

## Cross-File Instances

Typeclasses and instances can be defined in different files. As long as both files are loaded (via `use`), the Registry has the full picture:

**`lib/MyApp/Types.pm`**:

```typist
package MyApp::Types;
use v5.40;
use Typist;

BEGIN {
    typeclass Printable => 'T', +{
        to_str => '(T) -> Str',
    };
}

1;
```

**`lib/MyApp/Instances.pm`**:

```typist
package MyApp::Instances;
use v5.40;
use Typist;
use MyApp::Types;

BEGIN {
    instance Printable => 'Int', +{
        to_str => sub ($v) { "Int: $v" },
    };
}

1;
```

### Limitations

Static registration of cross-file instances records the instance's existence but uses empty method bodies (no coderefs). This means:

- Instance **existence** is tracked for static analysis (typeclass constraint checking works)
- Instance method **completeness** is checked at definition time (as always)
- Full method dispatch requires the defining module to be loaded at runtime

For the LSP, the Workspace component tracks instances per file and rebuilds the Registry on file changes.

---

## The Dispatch Namespace

When you write `typeclass Show => ...`, Typist creates dispatch functions in the `Show::` namespace:

- `Show::show(...)` -- the dispatch function for the `show` method

This is a **synthetic namespace** -- there is no `Show.pm` file on disk. The functions are installed by `install_dispatch` during typeclass registration.

This means you can call `Show::show(...)` from any package without importing anything. The dispatch function is globally available once the typeclass is defined.

---

## Complete Example

```typist
use v5.40;
use Typist;

BEGIN {
    # Define a typeclass
    typeclass Describable => 'T', +{
        describe => '(T) -> Str',
        summary  => '(T) -> Str',
    };

    # Define some types
    struct Person => (name => 'Str', age => 'Int');
    struct Item   => (name => 'Str', optional(desc => 'Str'));

    # Instances
    instance Describable => 'Person', +{
        describe => sub ($p) {
            $p->name . ", age " . $p->age;
        },
        summary => sub ($p) {
            $p->name;
        },
    };

    instance Describable => 'Item', +{
        describe => sub ($i) {
            $i->name . ($i->desc ? ": " . $i->desc : "");
        },
        summary => sub ($i) {
            $i->name;
        },
    };
}

# Use via dispatch
my $alice = Person(name => "Alice", age => 30);
my $widget = Item(name => "Widget", desc => "A useful thing");

say Describable::describe($alice);    # "Alice, age 30"
say Describable::summary($widget);   # "Widget"

# With typeclass constraint
sub show_summary :sig(<T: Describable>(T) -> Str) ($x) {
    "[" . Describable::summary($x) . "]";
}

say show_summary($alice);    # "[Alice]"
say show_summary($widget);  # "[Widget]"
```

---

## Next

- [Algebraic Effects](effects.md) -- tracked side effects with scoped handlers and the effect row system
