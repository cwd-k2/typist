# Prelude: Built-in Types and Functions

Typist's prelude defines the primitive type hierarchy, standard type constructors, built-in effect labels, and type annotations for Perl's core functions. The prelude is installed automatically into every registry.

## Primitive Types

| Type | Kind | Description |
|------|------|-------------|
| `Any` | `*` | Top type. Every type is a subtype of `Any` |
| `Void` | `*` | No meaningful return value |
| `Never` | `*` | Bottom type. No values inhabit this type |
| `Undef` | `*` | Perl's `undef` value |
| `Bool` | `*` | Boolean (`0`/`1` in boolean context) |
| `Int` | `*` | Integer |
| `Double` | `*` | Floating-point number |
| `Num` | `*` | Numeric supertype |
| `Str` | `*` | String |

### Subtype Hierarchy

```
                Any
              / | \ \
           Str Num  | Void
            |   |   |
            | Double |
            |   |   |
            | Int   |
            |   |  Undef
            | Bool
            |
          Never
```

The subtyping relationships are:

- `Bool <: Int <: Double <: Num <: Any`
- `Str <: Any`
- `Undef <: Any`
- `Void <: Any`
- `Never <: T` for all types `T` (bottom type)

## Type Constructors

| Constructor | Kind | Description | Desugaring |
|-------------|------|-------------|------------|
| `ArrayRef[T]` | `* -> *` | Scalar reference to array | -- |
| `HashRef[K, V]` | `* -> * -> *` | Scalar reference to hash | -- |
| `Tuple[T...]` | `* -> ... -> *` | Fixed-length array reference | -- |
| `Ref[T]` | `* -> *` | Scalar reference | -- |
| `Maybe[T]` | `* -> *` | Optional value | `T | Undef` |
| `CodeRef[A -> R]` | `* -> *` | Function reference | `(A) -> R` |
| `Array[T]` | `* -> *` | List type (list context) | -- |
| `Hash[K, V]` | `* -> * -> *` | List type (list context) | -- |
| `Handler[E]` | `* -> *` | Effect handler | -- |

### Array vs ArrayRef

`Array[T]` and `ArrayRef[T]` are distinct types:

- `ArrayRef[T]` is a scalar reference (`$ref = [1, 2, 3]`). Use for variables and parameters.
- `Array[T]` is a list type representing list-producing expressions. Use for return types in list context.

The same distinction applies to `Hash[K, V]` vs `HashRef[K, V]`.

### Subtyping for Constructors

- `ArrayRef` is covariant: `ArrayRef[Int] <: ArrayRef[Num]`
- `HashRef` is covariant in both parameters: `HashRef[Str, Int] <: HashRef[Any, Num]`
- `Record <: HashRef[Str, V]` when all field values are subtypes of `V`

## Built-in Effect Labels

| Label | Operations | Ambient | Description |
|-------|-----------|---------|-------------|
| `IO` | (none) | Yes | Standard I/O, system interaction, time, randomness |
| `Exn` | `throw: (Any) -> Never` | Yes | Exception handling. `Exn::throw($err)` bridges to `die` |
| `Decl` | (none) | Yes | Type declarations (Typist's own `typedef`, `struct`, etc.) |

Ambient effects do not require an explicit `handle` block. They are automatically satisfied and are never reported as `EffectMismatch` errors.

`Exn` is the only built-in effect with an operation. `Exn::throw($err)` is installed as a sub that calls `die`.

## Built-in Function Annotations

All built-in annotations are registered under the `CORE::` namespace. These are the default type signatures for Perl's built-in functions.

### I/O Functions (`![IO]`)

| Function | Signature |
|----------|-----------|
| `say` | `(...Any) -> Bool ![IO]` |
| `print` | `(...Any) -> Bool ![IO]` |
| `warn` | `(...Any) -> Bool ![IO]` |
| `open` | `(...Any) -> Bool ![IO]` |
| `close` | `(Any) -> Bool ![IO]` |
| `read` | `(Any, Any, Int) -> Int ![IO]` |
| `write` | `(Any, Any, Int) -> Int ![IO]` |
| `binmode` | `(Any) -> Bool ![IO]` |
| `eof` | `(Any) -> Bool ![IO]` |
| `seek` | `(Any, Int, Int) -> Bool ![IO]` |
| `tell` | `(Any) -> Int ![IO]` |
| `rand` | `(...Num) -> Double ![IO]` |
| `srand` | `(...Int) -> Int ![IO]` |
| `sleep` | `(...Int) -> Int ![IO]` |
| `time` | `() -> Int ![IO]` |
| `localtime` | `(...Int) -> Any ![IO]` |
| `gmtime` | `(...Int) -> Any ![IO]` |
| `require` | `(Any) -> Bool ![IO]` |
| `use` | `(Any) -> Bool ![IO]` |
| `system` | `(...Any) -> Int ![IO]` |
| `exec` | `(...Any) -> Never ![IO]` |

### Exception Functions (`![Exn]`)

| Function | Signature |
|----------|-----------|
| `die` | `(...Any) -> Never ![Exn]` |
| `eval` | `(Any) -> Any ![Exn]` |
| `exit` | `(...Int) -> Never ![Exn]` |

### String Functions (pure)

| Function | Signature |
|----------|-----------|
| `length` | `(Str) -> Int` |
| `substr` | `(Str, Int, ...Int) -> Str` |
| `uc` | `(Str) -> Str` |
| `lc` | `(Str) -> Str` |
| `ucfirst` | `(Str) -> Str` |
| `lcfirst` | `(Str) -> Str` |
| `index` | `(Str, Str, ...Int) -> Int` |
| `rindex` | `(Str, Str, ...Int) -> Int` |
| `chomp` | `(Any) -> Int` |
| `chop` | `(Any) -> Str` |
| `chr` | `(Int) -> Str` |
| `ord` | `(Str) -> Int` |
| `hex` | `(Str) -> Int` |
| `oct` | `(Str) -> Int` |
| `quotemeta` | `(Str) -> Str` |
| `sprintf` | `(Str, ...Any) -> Str` |

### Numeric Functions (pure)

| Function | Signature |
|----------|-----------|
| `abs` | `(Num) -> Num` |
| `int` | `(Num) -> Int` |
| `sqrt` | `(Num) -> Double` |
| `log` | `(Num) -> Double` |
| `exp` | `(Num) -> Double` |
| `sin` | `(Num) -> Double` |
| `cos` | `(Num) -> Double` |
| `atan2` | `(Num, Num) -> Double` |

### Type/Value Introspection (pure)

| Function | Signature |
|----------|-----------|
| `defined` | `(Any) -> Bool` |
| `ref` | `(Any) -> Str` |
| `wantarray` | `() -> Bool` |
| `caller` | `(...Int) -> Any` |

### Array Functions (pure)

| Function | Signature |
|----------|-----------|
| `scalar` | `(Any) -> Int` |
| `push` | `(Any, ...Any) -> Int` |
| `pop` | `(Any) -> Any` |
| `shift` | `(...Any) -> Any` |
| `unshift` | `(Any, ...Any) -> Int` |
| `splice` | `(Any, ...Any) -> Any` |
| `reverse` | `(...Any) -> Any` |
| `sort` | `(...Any) -> Any` |
| `map` | `(Any, ...Any) -> Any` |
| `grep` | `(Any, ...Any) -> Any` |

### Hash Functions (pure)

| Function | Signature |
|----------|-----------|
| `keys` | `(Any) -> Any` |
| `values` | `(Any) -> Any` |
| `each` | `(Any) -> Any` |
| `delete` | `(Any) -> Any` |
| `exists` | `(Any) -> Bool` |

### String Matching (pure)

| Function | Signature |
|----------|-----------|
| `split` | `(Any, ...Any) -> Any` |
| `join` | `(Str, ...Any) -> Str` |
| `pack` | `(Str, ...Any) -> Str` |
| `unpack` | `(Str, Str) -> Any` |

### Typist Declaration Functions (`![Decl]`)

| Function | Signature |
|----------|-----------|
| `typedef` | `(...Any) -> Void ![Decl]` |
| `newtype` | `(...Any) -> Void ![Decl]` |
| `effect` | `(...Any) -> Void ![Decl]` |
| `typeclass` | `(...Any) -> Void ![Decl]` |
| `instance` | `(...Any) -> Void ![Decl]` |
| `declare` | `(Str, Str) -> Void ![Decl]` |
| `datatype` | `(...Any) -> Void ![Decl]` |
| `struct` | `(...Any) -> Void ![Decl]` |

## Overriding Prelude Annotations

Use `declare` to override any prelude annotation with a custom one:

```typist
use Typist;

BEGIN {
    declare say => '(Str) -> Void ![Console]';
    declare chomp => '(Str) -> Str';
}
```

The last `declare` for a given name wins (simple replacement). This works because `register_function` uses plain assignment -- later writes overwrite earlier entries in the registry.

Override is useful when:

- You want a more specific signature than the prelude provides (e.g., narrowing `(...Any)` to specific types).
- You define a custom effect label and want builtins to use it instead of `IO`.
- You need to annotate a function that is not in the prelude.

`declare` can annotate any function, not just builtins:

```typist
BEGIN {
    declare 'Some::Module::process' => '(Str) -> Int ![IO]';
}
```

## Gradual Typing Defaults

When no annotation is present, Typist applies these defaults:

- **Unannotated functions**: treated as `(Any...) -> Any` with no effect constraints (pure).
- **Unannotated variables**: type is inferred from the initializer, or `Any` if no initializer.
- **Partially annotated functions** (return type present but not all params): return type is checked, unknown params are `Any`.

The gradual typing principle: **no annotation = no constraint**. Types use `Any` (compatible with all types in both directions), effects use pure (no effects declared, so no effect checking applies).
