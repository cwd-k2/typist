# Static vs Runtime Mode

Typist has two enforcement modes. The default is static-only, which catches errors at compile time with zero runtime cost. The opt-in runtime mode adds per-call and per-assignment enforcement for situations where static analysis is not sufficient.

---

## The Two Modes

```perl
use Typist;            # Static-only (default)
use Typist -runtime;   # Static + runtime enforcement
```

You can also enable runtime mode via an environment variable:

```bash
TYPIST_RUNTIME=1 perl my_script.pl
```

The environment variable is useful for enabling runtime checks in test environments without modifying source code.

---

## What Each Mode Provides

| Mechanism | `use Typist` | `use Typist -runtime` |
|-----------|:-----------:|:---------------------:|
| Static analysis (CHECK phase) | ON | ON |
| CHECK-phase diagnostics | ON | ON |
| Structural checks (arity, required fields, unknown fields) | ON | ON |
| Effect dispatch (`handle` / operations) | ON | ON |
| Typeclass dispatch | ON | ON |
| **Constructor type validation** | **OFF** | **ON** |
| **Tie::Scalar variable monitoring** | **OFF** | **ON** |
| **Wrapped sub parameter/return checks** | **OFF** | **ON** |
| Runtime performance cost | Zero | Per-call / per-assignment |

Both modes always run the full static analysis pipeline. The difference is what happens *at runtime* when your program executes.

---

## Static-Only Mode (Default)

With `use Typist`, type errors are reported as warnings during the CHECK phase -- after compilation but before your program's main execution begins. The LSP server provides the same diagnostics inline in your editor.

### What is checked statically

- **Type annotations**: parameter types, return types, generic bounds, typeclass constraints.
- **Effect inclusion**: callee effects are a subset of caller effects.
- **Protocol states**: operations are called in valid sequence.
- **Call sites**: argument types and arity at function call sites.
- **Variable types**: inferred types from initializers, assignment compatibility.
- **Structural errors**: unknown struct fields, missing required fields, constructor arity.
- **Well-formedness**: alias cycles, undefined types, kind errors, unreachable protocol operations.

### What executes at runtime

- **Structural checks**: struct/newtype/datatype constructors validate field names, required fields, and argument arity. These checks are cheap (hash key existence, array length) and catch API misuse:

```perl
BEGIN {
    struct Point => (x => 'Int', y => 'Int');
}

Point(x => 1, y => 2);           # OK
Point(x => 1);                    # dies: missing required field 'y'
Point(x => 1, y => 2, z => 3);   # dies: unknown field 'z'
```

- **Effect dispatch**: `handle` and effect operations work normally. Handler stack, scoped push/pop, nested shadowing -- all active.
- **Typeclass dispatch**: `instance` methods resolve and dispatch correctly.
- **Original subs execute directly**: no wrappers, no interception, no overhead. A function annotated with `:sig((Int, Int) -> Int)` runs exactly as if the annotation were not there.

### Performance characteristics

Static-only mode adds **zero runtime overhead** to your program. The `:sig()` attributes are processed during compilation. At runtime, the original subroutine executes without any wrapper, proxy, or interception.

---

## Runtime Mode

With `use Typist -runtime`, three additional enforcement mechanisms activate:

### 1. Tied scalar variables

Variables annotated with `:sig(Type)` are monitored via Perl's `tie` mechanism. Every assignment is checked against the declared type:

```perl
use Typist -runtime;

my $count :sig(Int) = 0;
$count = 42;        # OK
$count = "hello";   # dies: type error -- $count expected Int, got 'hello'
$count = undef;     # dies: type error -- $count expected Int, got undef
```

The `Tie::Scalar` implementation intercepts `STORE` and calls `$type->contains($value)`. On failure, it `die`s with a descriptive message including the variable name, expected type, and actual value.

### 2. Wrapped subroutines

Functions with `:sig()` annotations are wrapped to check parameter types on entry and return types on exit:

```perl
use Typist -runtime;

sub add :sig((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

add(1, 2);          # OK
add(1, "hello");    # dies: parameter 2 expected Int, got 'hello'
```

For generic functions, the wrapper performs type argument inference and checks constraints:

```perl
sub first :sig(<T>(ArrayRef[T]) -> T) ($arr) {
    $arr->[0];
}

first([1, 2, 3]);       # OK: T = Int
first("not an array");  # dies: expected ArrayRef[T]
```

### 3. Constructor type validation

Newtype, datatype, and struct constructors perform full type checking on their arguments:

```perl
use Typist -runtime;

BEGIN {
    newtype UserId => 'Int';
    struct Point => (x => 'Int', y => 'Int');
}

UserId(42);         # OK
UserId("hello");    # dies: UserId expected Int, got 'hello'

Point(x => 1, y => 2);        # OK
Point(x => "a", y => 2);      # dies: field 'x' expected Int, got 'a'
```

Without `-runtime`, constructors only check structural validity (field names, arity). With `-runtime`, they additionally validate that each field value matches its declared type via `contains()` and `infer_value()`.

### Performance characteristics

Runtime mode adds overhead to every annotated function call (parameter and return checking), every assignment to a `:sig()` variable (tied scalar STORE), and every constructor invocation (type validation). The cost depends on the complexity of the types involved:

- Simple types (atoms, newtypes): fast `contains()` check.
- Parameterized types (ArrayRef[Int]): element-by-element check.
- Generic functions: type inference + constraint resolution per call.

This overhead is acceptable for development and testing but is typically not desirable in production.

---

## Structural Checks (Always On)

Regardless of mode, constructors perform structural validation. This is cheap and catches common API errors:

### Struct constructors

```perl
BEGIN {
    struct Config => (
        host => 'Str',
        port => 'Int',
        optional(debug => 'Bool'),
    );
}

Config(host => "localhost", port => 8080);           # OK
Config(host => "localhost");                          # dies: missing field 'port'
Config(host => "localhost", port => 8080, foo => 1); # dies: unknown field 'foo'
```

### Datatype constructors

```perl
BEGIN {
    datatype 'Tree[T]' => (
        Leaf => ['T'],
        Node => ['Tree[T]', 'T', 'Tree[T]'],
    );
}

Leaf(1);              # OK
Leaf(1, 2);           # dies: wrong number of arguments
Node(Leaf(1), 2);     # dies: wrong number of arguments (expects 3)
```

### Newtype constructors

```perl
BEGIN {
    newtype UserId => 'Int';
}

UserId(42);           # OK (structural: exactly 1 argument)
UserId();             # dies: wrong number of arguments
UserId(1, 2);         # dies: wrong number of arguments
```

---

## When to Use Which

### Static-only (`use Typist`) is appropriate for:

- **Production code** where performance matters. Zero overhead means types are free.
- **Libraries** consumed by other code. Static analysis catches errors at build time.
- **Code with good LSP coverage.** If your editor shows diagnostics inline, CHECK-phase output is redundant.
- **Code where the static analyzer covers your needs.** For most Perl code, the PPI-based analyzer catches the same errors that runtime checks would.

### Runtime mode (`use Typist -runtime`) is appropriate for:

- **Test environments.** Enable runtime checks in your test suite to catch boundary violations that static analysis might miss:

```perl
# t/my_test.t
use Typist -runtime;
use Test::More;
# ... tests run with full type enforcement
```

- **Development and debugging.** Get immediate feedback when a type violation occurs, with a stack trace pointing to the exact call site.
- **External input boundaries.** When your code receives data from external sources (user input, API responses, file parsing), runtime validation ensures the data matches your type expectations.
- **Code that static analysis cannot fully cover.** Dynamic dispatch, eval'd code, and complex metaprogramming may escape static analysis. Runtime checks provide a safety net.

### A common pattern

Use static-only in your library code and runtime mode in your tests:

```perl
# lib/MyApp/User.pm
use Typist;    # static-only in production code

# t/user.t
use Typist -runtime;    # runtime checks in tests
use MyApp::User;
```

---

## Suppressing CHECK Output

When using the LSP server for diagnostics, the CHECK-phase output is redundant. Suppress it with:

```bash
export TYPIST_CHECK_QUIET=1
```

This sets `$Typist::CHECK_QUIET`, which skips the `_check_analyze()` pass in the CHECK block. The structural checks (Checker) still run; only the per-file Analyzer pass is skipped.

This is useful when:

- Your editor provides inline diagnostics via the LSP server.
- You run your program frequently during development and want to avoid duplicate warnings.
- You use the `typist-check` CLI tool separately for batch analysis.

---

## Environment Variables

| Variable | Effect |
|----------|--------|
| `TYPIST_RUNTIME=1` | Enables runtime enforcement (same as `use Typist -runtime`) |
| `TYPIST_CHECK_QUIET=1` | Skips CHECK-phase static analysis output |

Both can be set per-invocation or in your shell profile.

---

## Diagnostic Flow

The complete diagnostic pipeline, showing when each layer operates:

```
Compilation                         Runtime
───────────────────────────────     ──────────────────────────

Source → PPI parse
  ↓
Attribute processing
  ↓ :sig() parsed, registered
  ↓ (runtime: wrap subs, tie vars)
  ↓
CHECK phase
  ↓ Checker: structural checks
  ↓ Analyzer: type/effect/protocol
  ↓ Warnings emitted
                                    main() begins
                                      ↓
                                    Structural checks (always)
                                      ↓ arity, fields
                                    Type checks (runtime only)
                                      ↓ contains(), infer_value()
                                    Wrapped subs (runtime only)
                                      ↓ param/return checks
                                    Tied scalars (runtime only)
                                      ↓ assignment checks
```

---

## Summary

| Aspect | Static-only | Runtime |
|--------|:-----------:|:-------:|
| Static analysis | Full | Full |
| Runtime overhead | Zero | Per-call / per-assignment |
| Structural checks | Always | Always |
| Type enforcement | Compile time only | Compile time + runtime |
| Use case | Production, libraries | Tests, development, input boundaries |
| Enable via | `use Typist` (default) | `use Typist -runtime` or `TYPIST_RUNTIME=1` |

**Previous**: [Gradual Typing](gradual-typing.md) -- incremental adoption.
