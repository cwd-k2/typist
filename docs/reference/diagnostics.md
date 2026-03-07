# Diagnostics Reference

Complete reference for all diagnostic kinds emitted by Typist's static analyzer, CHECK phase, and LSP server.

## Severity Levels

Typist uses an internal five-level severity scale. The LSP server maps these to the four standard LSP severity levels.

| Internal | CLI Label | LSP Severity | LSP Label | Description |
|----------|-----------|--------------|-----------|-------------|
| 1 | error | 1 | Error | Critical — breaks type resolution |
| 2 | error | 2 | Warning | Type errors, arity mismatches |
| 3 | warning | 3 | Information | Undeclared variables, unknown effects |
| 4 | warning | 4 | Hint | Informational hints |
| 5 | hint | 4 | Hint | Opt-in gradual typing hints |

!!! note
    Internal severity 2 maps to LSP "Warning" (not "Error") per the LSP specification, but `typist-check` CLI labels it as "error". Similarly, internal severity 3 is LSP "Information" but CLI "warning".

The `typist-check` CLI uses the following exit codes:

| Exit Code | Meaning |
|-----------|---------|
| 0 | All clean (no diagnostics) |
| 1 | Errors found (severity 1--2) |
| 2 | Warnings only (severity 3--4) |

Severity 5 diagnostics (hints) are not counted in the summary and are only shown in `--verbose` mode.

## Diagnostic Kinds

### CycleError (Severity 1)

A cycle was detected in type alias resolution or typeclass inheritance.

**Example messages:**

```
CycleError: cycle detected resolving type 'A'
CycleError: Superclass cycle detected involving 'Eq'
```

**Cause:** Circular type alias definitions without a type constructor to break the recursion, or circular typeclass inheritance chains.

```typist
# Cycle: A -> B -> A (no type constructor)
typedef A => 'B';
typedef B => 'A';

# Typeclass cycle
typeclass Foo => (extends => 'Bar', show => '(Foo) -> Str');
typeclass Bar => (extends => 'Foo', display => '(Bar) -> Str');
```

**Fix:** Break the cycle by introducing a type constructor:

```typist
typedef A => 'ArrayRef[A]';  # OK: recursive through ArrayRef
```

For typeclass cycles, restructure the inheritance hierarchy.

---

### TypeMismatch (Severity 2)

A value, argument, assignment, or return type does not match its declared type.

**Example messages:**

```
Type error in main: expected Int, got Str in argument 1 of add at line 5
Assignment to $count: expected Int, got Str
Return type: expected Int, got Str in function 'calculate'
```

**Cause:** Passing the wrong type to a function, assigning an incompatible value to an annotated variable, or returning a value that does not match the declared return type.

```typist
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
add("hello", 42);  # TypeMismatch: expected Int, got Str in argument 1

my $count :sig(Int) = "not a number";  # TypeMismatch: expected Int, got Str
```

**Fix:** Correct the value to match the declared type, or update the type annotation. The LSP provides code actions that can auto-fix annotations.

---

### ArityMismatch (Severity 2)

A function call has the wrong number of arguments.

**Example messages:**

```
add() expects 2 arguments, got 3
process() expects at least 1 argument, got 0
```

**Cause:** Calling a function with too many or too few arguments relative to its `:sig()` declaration. For variadic functions (`...Type`), the minimum arity is the number of non-variadic parameters. Default parameters reduce the minimum arity.

**Fix:** Match the number of arguments to the function's declared parameter count.

---

### ResolveError (Severity 2)

A type name referenced in an annotation could not be resolved.

**Example messages:**

```
ResolveError: unknown type 'Foobar'
ResolveError: cannot resolve alias 'ProductList'
```

**Cause:** The type name is misspelled, not defined, or not visible from the current package. Types must be defined in a `BEGIN` block (or loaded from a module) before they can be used in `:sig()` annotations.

```typist
sub process :sig((Prodcut) -> Void) ($p) { ... }  # Typo: 'Prodcut'
```

**Fix:** Check spelling. Ensure the type is defined in a `BEGIN` block. Ensure the defining module is imported with `use`.

---

### EffectMismatch (Severity 2)

A function performs effects that are not declared in its caller's effect annotation.

**Example messages:**

```
Function process() calls read_file() which requires ![IO], but process() has no effect annotation
Effect mismatch in 'handler': callee requires ![Logger] but caller only has ![IO]
```

**Cause:** A function calls another function that declares effects, but the caller either has no effect annotation or does not include the callee's effects in its own annotation.

```typist
sub read_file :sig((Str) -> Str ![IO]) ($path) { ... }
sub process :sig((Str) -> Str) ($path) {
    read_file($path);  # EffectMismatch: read_file requires ![IO]
}
```

**Fix:** Add the missing effects to the caller's annotation:

```typist
sub process :sig((Str) -> Str ![IO]) ($path) {
    read_file($path);  # OK
}
```

The LSP provides code actions to auto-add missing effect labels.

Note: Ambient effects (`IO`, `Exn`, `Decl`) do not trigger `EffectMismatch` when the callee performs only ambient effects.

---

### ProtocolMismatch (Severity 2)

An effect protocol state machine violation was detected.

**Example messages:**

```
Protocol DB: operation 'query' is not allowed in state 'Idle' (in process())
Protocol DB: function process() ends in state 'Active' but expected '*'
Protocol DB: loop body changes state from 'Idle' to 'Active' (must be idempotent)
Protocol DB: handle body must end at '*' but ends at 'Active'
Protocol DB: state 'Unknown' appears in transitions but is not in the declared states list
```

**Cause:** Effect operations are called in the wrong protocol state, a function does not return to the expected terminal state, a loop body changes state non-idempotently, or a `handle` block does not reset to ground state.

**Fix:** Ensure operations are called in the correct state sequence as defined by the effect's protocol. Check that functions begin and end in their declared states.

---

### TypeError (Severity 2)

A general type error from structural validation. This is a catch-all kind for type errors not covered by the more specific kinds above.

---

### UnknownTypeClass (Severity 2)

A typeclass referenced in an annotation or instance declaration was not found.

**Example messages:**

```
UnknownTypeClass: typeclass 'Showable' is not defined
```

**Fix:** Ensure the typeclass is defined with `typeclass` in a `BEGIN` block and that the defining module is imported.

---

### InvalidBound (Severity 3)

A bound expression in a generic parameter declaration is malformed.

**Example messages:**

```
Invalid bound expression 'NotAType' for T in main::process: ...
```

**Cause:** The bound type in `<T: Bound>` cannot be parsed or does not resolve to a known type.

**Fix:** Ensure the bound is a valid type name or typeclass name.

---

### KindError (Severity 3)

A kind mismatch in type application.

**Example messages:**

```
Kind error in parameter of main::process: Type 'Int' has kind '*', expected '* -> *'
Kind error in return of main::transform: ...
```

**Cause:** A type is applied to type arguments but its kind does not allow it, or a higher-kinded type variable is used incorrectly.

```typist
# Int has kind *, cannot take type arguments
sub bad :sig(<F: * -> *>(F[Int]) -> F[Str]) ($x) { ... }
bad(42);  # KindError: Int has kind *, expected * -> *
```

**Fix:** Ensure type applications match the expected kind.

---

### UndeclaredTypeVar (Severity 3)

A type variable appears in a function signature but is not declared in the generic parameter list.

**Example messages:**

```
Type variable 'T' in main::process is not declared in generics
```

**Cause:** Using a type variable (single uppercase letter) in a `:sig()` without declaring it in `<...>`:

```typist
sub process :sig((T) -> T) ($x) { ... }  # UndeclaredTypeVar: T not declared
```

**Fix:** Add the type variable to the generic parameter list:

```typist
sub process :sig(<T>(T) -> T) ($x) { ... }
```

---

### UndeclaredRowVar (Severity 3)

A row variable appears in an effect annotation but is not declared in the generic parameter list.

**Example messages:**

```
Row variable 'r' in main::process is not declared
```

**Fix:** Declare the row variable in the generic parameter list with the `Row` kind:

```typist
sub process :sig(<T, r: Row>(T) -> T ![Console, r]) ($x) { ... }
```

---

### UnknownEffect (Severity 3)

An effect label in a `:sig()` annotation does not correspond to any registered effect.

**Example messages:**

```
Unknown effect label 'MyEffect' in main::process
```

**Cause:** The effect is referenced in `![MyEffect]` but was never defined with `effect MyEffect => ...`.

**Fix:** Define the effect in a `BEGIN` block:

```typist
BEGIN {
    effect MyEffect => +{ op_name => '(Str) -> Void' };
}
```

---

### UnknownType (Severity 4)

A type name in an annotation could not be resolved. Lower severity than `ResolveError` -- this is a hint rather than a hard error.

**Example messages:**

```
Unknown type 'Widget' referenced in main::process
```

---

### ImportHint (Severity 4)

A type is used in a `:sig()` annotation but the package that defines it is not imported.

**Example messages:**

```
Type 'Product' may need import (defined in Shop::Types)
```

**Cause:** The type is defined in another package via `typedef`, `newtype`, `struct`, etc., and that package is not imported with `use` in the current file.

**Fix:** Add `use Shop::Types;` (or the appropriate module) to your file.

Note: Built-in types (primitives, prelude types) have no provenance and are always visible -- they never trigger `ImportHint`.

---

### GradualHint (Severity 5)

An opt-in diagnostic that identifies locations where type checking was skipped because inferred types contain `Any`. Only shown in verbose mode.

**Example messages:**

```
Argument 1 of process() not checked: inferred type contains Any (Any)
Return of calculate() not checked: inferred type contains Any (Any)
```

**Cause:** Gradual typing -- when a value's type cannot be inferred more precisely than `Any`, type checks against it are skipped. These hints help identify where type coverage is incomplete.

This diagnostic is severity 5, which means it is mapped to LSP Hint and not counted in the `typist-check` summary.

## Suppression

### `@typist-ignore` Comment

A comment containing `@typist-ignore` on line N suppresses all diagnostics on line N+1:

```typist
# @typist-ignore
my $x :sig(Int) = "not an int";  # No diagnostic
```

The comment can contain other text:

```typist
# TODO: fix this later @typist-ignore
risky_call();
```

### `TYPIST_CHECK_QUIET`

Setting `TYPIST_CHECK_QUIET=1` skips the entire CHECK-phase static analysis. Use this when the LSP server provides diagnostics, to avoid duplicate output:

```bash
export TYPIST_CHECK_QUIET=1
```

This only affects the CHECK-phase STDERR output. The LSP server and `typist-check` CLI are not affected.

## Diagnostic Locations

Each diagnostic includes:

| Field | Description |
|-------|-------------|
| `line` | Line number (1-based) |
| `col` | Column number (1-based) |
| `end_line` | End line (optional, for range) |
| `end_col` | End column (optional, for range) |
| `file` | Source file path |
| `kind` | Diagnostic kind (e.g., `TypeMismatch`) |
| `message` | Human-readable description |
| `severity` | Internal severity (1--5) |
| `expected_type` | Expected type string (when applicable) |
| `actual_type` | Actual type string (when applicable) |
| `suggestions` | Suggested fixes (used by LSP code actions) |

## LSP Code Actions

The LSP server provides quickfix code actions for certain diagnostic kinds:

| Diagnostic | Code Action |
|------------|-------------|
| `TypeMismatch` (annotation) | Update `:sig()` annotation to match inferred type |
| `EffectMismatch` | Add missing effect label to caller's `:sig()` |
| `ArityMismatch` | (no auto-fix) |

Code actions appear as lightbulb suggestions in the editor when the cursor is on a diagnostic.
