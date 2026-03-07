# Gradual Typing

Typist implements gradual typing: you annotate at your own pace, and Typist checks proportionally to your annotation density. No annotation means no constraint -- not an error. This lets you adopt Typist incrementally, starting with the boundaries that matter most.

---

## The Core Principle

**No annotation = no constraint.**

- An unannotated function is not a type error. It is simply not checked.
- Typist never forces you to annotate everything. It checks what you declare and leaves the rest alone.
- The more you annotate, the more Typist can verify. The less you annotate, the less it gets in your way.

This applies uniformly to types, effects, and protocol states.

---

## Annotation Levels

Functions exist on a spectrum from fully annotated to completely unannotated:

### Fully annotated

```typist
sub greet :sig((Str) -> Str ![Console]) ($name) {
    Console::writeLine("Hello, $name!");
    "greeted $name";
}
```

All checks are active: parameter types, return type, and effect inclusion are verified statically.

### Partial -- no effects

```typist
sub add :sig((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}
```

Types are checked. The function is treated as pure (no effects). Calling a non-ambient effectful function from here produces an `EffectMismatch`.

### Partial -- no return type

```typist
sub process :sig((Str) -> Any) ($data) {
    # parameters checked, return type is Any (compatible with everything)
    ...
}
```

Parameters are checked. Return type is `Any`, which is compatible with all types in both directions, so no return-type mismatch is possible.

### Unannotated

```typist
sub helper ($x) {
    $x * 2;
}
```

Skipped entirely by all checkers. The function is treated as `(Any...) -> Any` with no effects. It can be called from anywhere without constraint.

### Summary table

| Level | Annotation | Type checks | Effect checks | Return check |
|-------|-----------|-------------|---------------|--------------|
| Full | `:sig((Str) -> Int ![IO])` | Parameters and return | Effect inclusion | Return type |
| Partial (no effect) | `:sig((Str) -> Int)` | Parameters and return | Treated as pure | Return type |
| Partial (Any return) | `:sig((Str) -> Any)` | Parameters only | Treated as pure | Skipped (Any) |
| Unannotated | `sub f ($x) { }` | Skipped | Skipped | Skipped |

---

## How Gradual Typing Works Internally

### The `Any` type

`Any` is the universal compatibility type. When inference produces `Any`, checks are skipped for that expression:

- `T <: Any` for all types T (every type is a subtype of `Any`)
- When inference produces `Any`, the type checker **skips the check entirely** rather than testing a subtype relation. This achieves bidirectional compatibility in practice -- `Any` never produces errors.

The mechanism is check-skipping, not a subtype relation: `Subtype->is_subtype(Any, Int)` returns false. But the checker never reaches the subtype engine because it short-circuits on `Any` first. This is exactly what you want for unannotated code.

### Unannotated functions as callers

When a function has no `:sig()`, all checkers skip it:

- **Type checker**: no parameter or return checks.
- **Effect checker**: no effect inclusion checks.
- **Protocol checker**: no protocol state verification.
- **Call checker**: no call-site argument checks originating from this function.

```typist
sub unannotated ($x) {
    effectful_fn($x);    # No EffectMismatch -- caller is not checked
    $x + "hello";        # No TypeMismatch -- caller is not checked
}
```

### Unannotated functions as callees

When an annotated function calls an unannotated function:

- **Type check**: the callee's return type is inferred as `Any`. Type checks involving `Any` are skipped.
- **Effect check**: the callee is treated as pure (no effects). No effect mismatch is generated.

```typist
sub helper ($x) { $x }    # unannotated

sub main :sig((Str) -> Str ![Console]) ($s) {
    helper($s);    # OK: helper is pure, return type is Any (compatible with Str)
}
```

---

## Flow Typing (Inference Without Annotation)

Even without `:sig()`, Typist infers types from initializer expressions. This is not enforcement -- it is information:

```typist
my $x = 42;                          # Inferred: Int
my $s = "hello";                      # Inferred: Str
my $p = Point(x => 1, y => 2);       # Inferred: Point
my $r = add(1, 2);                    # Inferred: Int (from add's return type)
my $a = [1, 2, 3];                    # Inferred: ArrayRef[Int]
```

These inferred types are used for:

- **Downstream type checking**: passing `$x` (inferred `Int`) to a function expecting `Str` produces a diagnostic.
- **LSP hover information**: hovering over `$x` in your editor shows `Int`.
- **LSP inlay hints**: inferred types appear as inline hints.
- **Narrowing**: `if (defined($x))` narrows a `Maybe[T]` to `T` in the then-branch.

The key difference from an explicit `:sig()` annotation: inferred types are not enforced on reassignment in runtime mode. Only `:sig()` annotations activate the `Tie::Scalar` monitor.

### Literal widening

Unannotated variable initializers widen literal types to their base atoms:

| Initializer | Inferred type | Note |
|-------------|--------------|------|
| `my $x = 0` | `Int` | Not `Literal(0, Int)` |
| `my $x = 42` | `Int` | Widened from literal |
| `my $r = 3.14` | `Double` | Widened from literal |
| `my $s = "hi"` | `Str` | Widened from literal |
| `my $b :sig(Bool) = 0` | `Bool` | Explicit annotation; 0/1 bidirectional inference |

The widening ensures that inferred types are stable. Without it, `my $x = 42` would get the literal type `42`, which is unnecessarily restrictive.

### The 0/1 special case

The values `0` and `1` default to `Literal(value, Int)`. They only become `Bool` when the expected type from a `:sig()` annotation is `Bool`:

```typist
my $x = 0;                # Int (no annotation -- widened to Int)
my $y :sig(Bool) = 0;     # Bool (annotation provides Bool context)
my $z :sig(Int) = 1;      # Int (annotation provides Int context)
```

---

## Effect Graduality

The same gradual principle applies to effects:

### Unannotated callers

An unannotated function can call anything without effect checks:

```typist
sub main () {
    effectful_fn("data");    # No check -- main is unannotated
}
```

### Unannotated callees

An unannotated callee is treated as pure:

```typist
sub helper ($x) { $x }    # unannotated -- pure

sub checked :sig(() -> Void ![Console]) () {
    helper("test");    # OK: helper has no effects
}
```

### Ambient effects

The built-in effects `IO`, `Exn`, and `Decl` are ambient. They are skipped in effect inclusion checks, so calling `say`, `die`, `eval`, etc. never produces an `EffectMismatch`:

```typist
sub pure :sig((Int) -> Int) ($n) {
    say "debug: $n";    # say is ![IO], but IO is ambient -- no error
    $n * 2;
}
```

---

## Adoption Strategy

Here is a recommended path for gradually adding type annotations to an existing codebase:

### 1. Start with module boundaries

Annotate the public API of your modules -- the functions that other modules call:

```typist
# Public API -- annotated
sub find_user :sig((UserId) -> Maybe[User]) ($id) { ... }
sub create_order :sig((User, ArrayRef[Item]) -> Order ![DB]) ($u, $items) { ... }

# Internal helpers -- leave unannotated for now
sub _normalize_name ($name) { ... }
sub _validate_email ($email) { ... }
```

This gives you the highest value-to-effort ratio: cross-module calls are where most type errors occur.

### 2. Add struct and newtype definitions

Nominal types are cheap to define and immediately useful:

```typist
BEGIN {
    newtype UserId => 'Int';
    newtype Email  => 'Str';

    struct User => (
        id    => 'UserId',
        name  => 'Str',
        email => 'Email',
    );
}
```

These give you constructor validation, accessor type information, and documentation -- all for a few lines of code.

### 3. Annotate effect-producing functions

Mark functions that perform I/O, database access, or other side effects:

```typist
sub fetch_user :sig((UserId) -> Maybe[User] ![DB]) ($id) { ... }
sub send_email :sig((Email, Str) -> Void ![IO]) ($to, $body) { ... }
```

This lets the effect checker verify that pure functions stay pure and that effectful functions declare their dependencies.

### 4. Work inward

As you gain confidence, annotate internal helpers and utility functions:

```typist
sub _normalize_name :sig((Str) -> Str) ($name) {
    lc($name) =~ s/\s+/ /gr =~ s/^\s+|\s+$//gr;
}
```

### 5. Enable runtime mode in tests

Add `-runtime` to your test files to catch boundary violations at test time:

```typist
use Typist -runtime;    # enables constructor type validation, tied scalars
```

This is especially valuable for catching issues at module boundaries where external data enters your typed domain.

---

## The @typist-ignore Directive

When you need to suppress a specific diagnostic, place `# @typist-ignore` on the line immediately before:

```typist
sub pure_fn :sig((Str) -> Str) ($s) {
    # @typist-ignore
    effectful_fn($s);    # No EffectMismatch reported on this line
    $s;
}
```

The directive suppresses all diagnostics on the *next* line. Use it sparingly -- it is an escape hatch, not a substitute for correct annotations.

---

## What Gradual Typing Does Not Do

- **It does not infer function signatures.** Only variable initializers get inferred types. Function parameters and return types require explicit `:sig()` annotations to be checked.
- **It does not propagate types across unannotated boundaries.** If function A is annotated and calls unannotated function B, B's return type is `Any`. The checker does not attempt to infer B's signature from its body.
- **It does not enforce inferred types on reassignment.** Only `:sig()` annotations activate runtime enforcement (in `-runtime` mode). Inferred types are informational.

---

## Summary

| Aspect | Annotated | Unannotated |
|--------|-----------|-------------|
| Type checking | Active | Skipped |
| Effect checking | Active | Skipped (pure) |
| Protocol checking | Active | Skipped |
| Variable inference | From annotation | From initializer (widened) |
| Runtime enforcement | `:sig()` + `-runtime` | Never |
| LSP hover/hints | From annotation or inference | From inference |

**Previous**: [Effect Protocols](effect-protocols.md) -- state machine verification.
**Next**: [Static vs Runtime](static-vs-runtime.md) -- the two enforcement modes.
