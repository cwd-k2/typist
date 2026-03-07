# Higher-Kinded Types

Types themselves have a classification system called *kinds*. Just as values have types (`42` has type `Int`), types have kinds (`Int` has kind `*`). Kinds let Typist reason about type constructors -- types that take type arguments to produce other types -- and catch misapplications at compile time.

---

## What Are Kinds?

A kind describes the "shape" of a type in terms of how many type arguments it expects.

| Kind | Meaning | Examples |
|------|---------|----------|
| `*` | A concrete type (takes no arguments) | `Int`, `Str`, `Bool`, `Point` |
| `* -> *` | A type constructor taking one argument | `ArrayRef`, `Maybe`, `Ref` |
| `* -> * -> *` | A type constructor taking two arguments | `HashRef` |
| `Row` | An effect row | Effect label sets |

When you write `ArrayRef[Int]`, you are applying the type constructor `ArrayRef` (kind `* -> *`) to the concrete type `Int` (kind `*`), producing a concrete type `ArrayRef[Int]` (kind `*`).

The arrow `->` in kind notation is right-associative: `* -> * -> *` means `* -> (* -> *)`, a constructor that takes one `*` argument and returns a `* -> *` constructor.

---

## Built-in Type Constructor Kinds

Typist maintains a kind table for the built-in parameterized types:

| Constructor | Kind | Application |
|-------------|------|-------------|
| `ArrayRef` | `* -> *` | `ArrayRef[Int]` : `*` |
| `HashRef` | `* -> * -> *` | `HashRef[Str, Int]` : `*` |
| `Maybe` | `* -> *` | `Maybe[Str]` : `*` |
| `Ref` | `* -> *` | `Ref[Int]` : `*` |

User-defined type constructors (registered via type classes or `KindChecker->register_kind`) extend this table.

---

## Kind Checking

The kind checker validates that type applications have the correct number and kind of arguments.

### Valid applications

```typist
my $nums :sig(ArrayRef[Int]) = [1, 2, 3];     # * -> * applied to * = *
my $map  :sig(HashRef[Str, Int]) = +{a => 1};  # * -> * -> * applied to *, * = *
my $opt  :sig(Maybe[Str]) = undef;             # * -> * applied to * = *
```

### Invalid applications

Applying a concrete type as if it were a type constructor:

```typist
# Int has kind *, not * -> *. It cannot take a type argument.
my $x :sig(Int[Str]) = 42;
```

This produces a kind error diagnostic:

```
KindError: Int applied to too many type arguments (1 excess)
```

Providing the wrong number of arguments to a known constructor:

```typist
# ArrayRef expects 1 type argument, not 2.
my $x :sig(ArrayRef[Int, Str]) = [1];
```

### Gradual kinding

For unknown type names (not in the built-in kind table and not registered), Typist assumes kind `*`. This is consistent with the overall gradual typing philosophy -- unknown types are treated permissively rather than rejected.

---

## HKT in Type Classes

Higher-kinded types become essential when defining type classes that abstract over type constructors. The classic example is `Functor`, which abstracts over any "container" that supports mapping.

### Declaring a higher-kinded type class

```typist
BEGIN {
    typeclass Functor => 'F: * -> *', +{
        fmap => '(F[A], CodeRef[A -> B]) -> F[B]',
    };
}
```

The declaration `F: * -> *` says that the type variable `F` is not a concrete type, but a type *constructor* -- something like `ArrayRef` or `Maybe` that takes one type argument.

In the method signature `(F[A], CodeRef[A -> B]) -> F[B]`:
- `F[A]` applies the constructor `F` to `A`, producing a concrete type
- `CodeRef[A -> B]` is a function from `A` to `B`
- `F[B]` is the same constructor applied to `B`

### Implementing an HKT instance

```typist
BEGIN {
    instance Functor => 'ArrayRef', +{
        fmap => sub ($arr, $f) { [map { $f->($_) } @$arr] },
    };
}
```

The instance declaration `instance Functor => 'ArrayRef'` says that `ArrayRef` (kind `* -> *`) satisfies the `Functor` class. The kind checker verifies that `ArrayRef` has the right kind to fill `F: * -> *`.

### Using the HKT method

```typist
my $doubled = Functor::fmap([1, 2, 3], sub ($x) { $x * 2 });
# $doubled = [2, 4, 6]

my $strings = Functor::fmap([10, 20, 30], sub ($x) { "[$x]" });
# $strings = ["[10]", "[20]", "[30]"]

# Chaining
my $result = Functor::fmap(
    Functor::fmap([1, 2, 3, 4, 5], sub ($x) { $x * $x }),
    sub ($x) { $x > 10 ? "big($x)" : "small($x)" },
);
# $result = ["small(1)", "small(4)", "small(9)", "big(16)", "big(25)"]
```

The dispatch system resolves `Functor::fmap` to the `ArrayRef` instance based on the first argument's type.

---

## Kind Inference

When no kind annotation is provided, Typist infers kinds from how type variables are used:

- A type variable used standalone (e.g., `T` in `(T) -> T`) is inferred as kind `*`.
- A type variable used with type arguments (e.g., `F[T]` in `(F[T]) -> F[T]`) is inferred as kind `* -> *`.

This means you rarely need to write kind annotations explicitly. They are primarily useful in type class definitions where the intent must be unambiguous:

```typist
# Without kind annotation, T defaults to *
typeclass Show => 'T', +{
    show => '(T) -> Str',
};

# With kind annotation, F is explicitly * -> *
typeclass Functor => 'F: * -> *', +{
    fmap => '(F[A], CodeRef[A -> B]) -> F[B]',
};
```

---

## Kind Expressions

Kind expressions use the same syntax as kind theory:

| Expression | Meaning |
|------------|---------|
| `*` | Concrete type |
| `Row` | Effect row |
| `* -> *` | Unary type constructor |
| `* -> * -> *` | Binary type constructor |
The arrow `->` is right-associative: `* -> * -> *` means `* -> (* -> *)`. Parenthesized grouping (e.g., `(* -> *) -> *`) is **not** currently supported by the kind parser.

---

## Registering Custom Kinds

Library authors can register custom type constructor kinds for their own parameterized types:

```typist
BEGIN {
    # Register a custom type constructor with kind * -> *
    Typist::KindChecker->register_kind('MyContainer',
        Typist::Kind->Arrow(Typist::Kind->Star, Typist::Kind->Star),
    );
}
```

After registration, the kind checker validates applications of `MyContainer` just like the built-in constructors. `MyContainer[Int]` is valid; `MyContainer[Int, Str]` is a kind error.

---

## Diagnostics

Kind errors are reported as `KindError` diagnostics by the static checker:

| Situation | Message |
|-----------|---------|
| Too many type arguments | `KindError: ArrayRef applied to too many type arguments (1 excess)` |
| Kind mismatch in argument | `KindError: F argument 1 has kind *, expected * -> *` |
| Union/intersection member not `*` | `KindError: union/intersection member has kind * -> *, expected *` |

These diagnostics surface during CHECK-phase analysis and in the LSP server.
