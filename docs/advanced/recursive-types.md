# Recursive Types

A recursive type is a type alias that refers to itself in its own definition. This lets you model tree-shaped data, nested JSON, linked lists, and other self-referential structures directly in the type system.

---

## Productive Recursion

A type alias can reference itself as long as the recursion passes through a *type constructor* like `ArrayRef`, `HashRef`, or a record type. The type constructor provides a base case (an empty container) that makes the recursion well-founded:

```typist
BEGIN {
    typedef IntList => 'Int | ArrayRef[IntList]';
}
```

`IntList` is either a plain `Int` or an `ArrayRef` whose elements are themselves `IntList` values. This allows arbitrarily nested structures:

```typist
my $flat   :sig(IntList) = 42;
my $nested :sig(IntList) = [1, [2, [3, 4]]];
my $empty  :sig(IntList) = [];
```

### JSON-like recursive type

A common practical example is modeling JSON values:

```typist
BEGIN {
    typedef JsonValue => 'Str | Num | Bool | Undef | ArrayRef[JsonValue] | HashRef[Str, JsonValue]';
}
```

This type captures the full structure of JSON: strings, numbers, booleans, null, arrays of JSON values, and objects (string-keyed hashes of JSON values):

```typist
my $json :sig(JsonValue) = +{
    name   => "Alice",
    scores => [95, 87, 92],
    meta   => +{ active => 1 },
    tags   => ["admin", "user"],
};
```

### Tree structure via records

Recursion can also go through record types:

```typist
BEGIN {
    typedef Tree => '{ value => Int, children => ArrayRef[Tree] }';
}

my $tree :sig(Tree) = +{
    value    => 1,
    children => [
        +{ value => 2, children => [] },
        +{ value => 3, children => [
            +{ value => 4, children => [] },
        ]},
    ],
};
```

---

## Recursive Types with Structs

Structs can participate in recursive type definitions through type aliases:

```typist
BEGIN {
    typedef CategoryTree => 'ArrayRef[Category]';
    struct Category => (name => 'Str', children => 'CategoryTree');
}
```

Here `Category` has a `children` field of type `CategoryTree`, which is an array of `Category` values. The recursion passes through `ArrayRef`, making it well-founded:

```typist
my $root = Category(
    name     => "root",
    children => [
        Category(name => "child1", children => []),
        Category(name => "child2", children => [
            Category(name => "grandchild", children => []),
        ]),
    ],
);
```

The order of definitions matters: the `typedef` for `CategoryTree` must appear before the `struct` for `Category` (or both in the same `BEGIN` block) so that the type name is resolvable when the struct is registered.

---

## Bare Cycles Are Rejected

Recursion without an intervening type constructor creates an infinite loop with no base case. Typist detects and rejects these:

```typist
BEGIN {
    typedef A => 'B';
    typedef B => 'A';
}
# Dies: Typist: alias cycle detected involving 'A'
```

Direct self-reference without a constructor is also rejected:

```typist
BEGIN {
    typedef Loop => 'Loop';
}
# Dies: alias cycle detected involving 'Loop'
```

The cycle detection runs during alias resolution in the Registry. When the resolver encounters the same type name twice in a single resolution chain, it raises an error.

### Why the distinction?

The difference between productive recursion (`ArrayRef[IntList]`) and bare cycles (`A = B = A`) is the presence of a *type constructor* that provides a base case. `ArrayRef[IntList]` can bottom out at `[]` (an empty array). `A = B = A` has no base case and cannot represent any finite value.

---

## Depth Limits

Even productive recursion could cause infinite loops during type operations like `contains()` (runtime type checking). Typist uses a depth limit to prevent this:

```typist
BEGIN {
    typedef Deep => 'ArrayRef[Deep]';
}

my $d :sig(Deep) = [];   # OK: empty array matches
```

The depth limit ensures that deeply nested `contains` checks terminate. In practice, this limit is generous enough to handle realistic data structures without triggering false negatives.

---

## Subtyping with Recursive Types

Recursive types participate in subtyping through alias resolution. When comparing `IntList <: SomeType`, the alias `IntList` is resolved to `Int | ArrayRef[IntList]`, and the comparison proceeds structurally.

Because alias resolution is lazy (resolved on first access, then cached), recursive types do not cause infinite expansion during subtype checks. The resolver handles cycles through its visited-set tracking.

```typist
BEGIN {
    typedef IntList  => 'Int | ArrayRef[IntList]';
    typedef NumList  => 'Num | ArrayRef[NumList]';
}

# After resolution:
#   IntList = Int | ArrayRef[IntList]
#   NumList = Num | ArrayRef[NumList]
# Int <: Num, so IntList values are compatible with NumList at the top level.
```

---

## Static Analysis

The static checker handles recursive types at several points:

- **Cycle detection** (Phase 2, `Static::Checker`): Scans all registered aliases for cycles. Non-productive cycles produce `CycleError` diagnostics with severity 5 (highest). These are surfaced in both the CHECK phase and the LSP.
- **Alias resolution** (Registry): Lazy resolution with a visited set. Productive recursion (through a type constructor) terminates because the resolver does not expand the inner alias recursively -- it returns an `Alias` node that is resolved on demand.
- **Runtime validation** (`contains`, `-runtime` mode): Uses a depth counter to prevent infinite recursion during value checking.

### Diagnostic example

```typist
BEGIN {
    typedef Foo => 'Bar';
    typedef Bar => 'Foo';
}
```

```
CycleError: Alias cycle detected involving 'Foo'    (line 2)
CycleError: Alias cycle detected involving 'Bar'    (line 3)
```

---

## Patterns and Guidelines

### Prefer union + constructor recursion

The most readable recursive types use a union of a base case and a recursive case wrapped in a type constructor:

```typist
typedef IntList  => 'Int | ArrayRef[IntList]';         # Base: Int
typedef StrTree  => 'Str | HashRef[Str, StrTree]';     # Base: Str
typedef JsonValue => 'Str | Num | Bool | Undef | ArrayRef[JsonValue] | HashRef[Str, JsonValue]';
```

### Use structs for named nodes

When tree nodes carry multiple fields, use a struct with a recursive typedef for the children:

```typist
BEGIN {
    typedef Expr => 'LitExpr | BinExpr';
    struct LitExpr => (value => 'Int');
    struct BinExpr => (op => 'Str', left => 'Expr', right => 'Expr');
}
```

This gives you named constructors, field accessors, and pattern matching via `isa` narrowing -- while the recursion is handled by the `Expr` typedef.

### Avoid deep nesting in runtime mode

With `-runtime` enabled, `contains()` checks walk the recursive structure. Very deep nesting (hundreds of levels) may hit the depth limit. If you need to validate deeply nested data at runtime, consider validating incrementally rather than in one pass.
