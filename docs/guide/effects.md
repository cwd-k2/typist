# Algebraic Effects

Algebraic effects let you track and control side effects in your type signatures. Instead of a function silently performing I/O, mutating state, or throwing exceptions, its effect requirements are declared in its type and enforced by the static checker. At runtime, effect operations dispatch to scoped handlers that you install explicitly.

---

## What Are Algebraic Effects?

In most languages, side effects are invisible. A function that reads from a database, writes to a log, or throws an exception looks exactly like a pure function in its signature. Algebraic effects make these dependencies explicit:

1. **Declaration**: you define an effect with named operations and their types.
2. **Annotation**: functions declare which effects they may perform via `![Effect]`.
3. **Checking**: the static analyzer verifies that callee effects are covered by caller effects.
4. **Handling**: at runtime, you provide scoped implementations for effect operations.

This gives you the documentation benefits of checked exceptions, the composability of dependency injection, and the scoping guarantees of dynamic binding -- all in one mechanism.

---

## Defining an Effect

Use `effect` inside a `BEGIN` block to define an effect with its operations:

```typist
use v5.40;
use Typist;

BEGIN {
    effect Console => +{
        log       => '(Str) -> Void',
        writeLine => '(Str) -> Void',
    };
}
```

This does three things:

1. Registers the effect `Console` in the Typist Registry.
2. Creates a synthetic namespace with callable subs: `Console::log(...)` and `Console::writeLine(...)`.
3. Makes `Console` available as an effect label in `:sig()` annotations.

The hashref maps operation names to type signature strings. Use `+{}` to disambiguate from a block.

### Multiple operations

An effect can have any number of operations:

```typist
BEGIN {
    effect State => +{
        get => '() -> Int',
        put => '(Int) -> Void',
    };

    effect Logger => +{
        log => '(Str) -> Void',
    };
}
```

Each operation becomes a sub in the effect's namespace: `State::get()`, `State::put($n)`, `Logger::log($msg)`.

---

## Annotating Effects on Functions

Declare which effects a function may perform by adding `![Effect1, Effect2]` after the return type in a `:sig()` annotation:

```typist
sub greet :sig((Str) -> Void ![Console]) ($name) {
    Console::log("Hello, $name!");
}

sub process :sig((Str) -> Str ![Console, Logger]) ($data) {
    Logger::log("Processing: $data");
    Console::writeLine("Done");
    "result";
}
```

The `!` is part of the effect syntax, not a negation. Read `![Console]` as "may perform the Console effect."

### Pure functions

A function with no `![]` clause is treated as pure:

```typist
sub add :sig((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}
```

### Generic functions with effects

All annotation features compose:

```typist
sub logged_first :sig(<T>(ArrayRef[T]) -> T ![Console]) ($arr) {
    Console::writeLine("taking first element");
    $arr->[0];
}
```

---

## Calling Effect Operations

Effect operations are called as qualified subs in the effect's namespace:

```typist
Console::log("hello");        # calls the Console effect's log operation
Console::writeLine("world");  # calls the Console effect's writeLine operation
State::put(42);               # calls the State effect's put operation
my $val = State::get();       # calls the State effect's get operation
```

At runtime, each call dispatches to the nearest handler on the handler stack. If no handler is installed, the call dies:

```
No handler for effect Console::log
```

---

## Handling Effects

The `handle` block installs scoped handlers for effect operations:

```typist
my $result = handle {
    Console::log("hello");
    Console::writeLine("world");
    42
} Console => +{
    log       => sub ($msg) { say ">> $msg" },
    writeLine => sub ($msg) { print $msg, "\n" },
};
# $result is 42
```

Key points:

- **No comma after the block.** `handle` uses the `(&@)` prototype, the same calling convention as `map` and `grep`. A comma between the block and the effect name silently breaks the call.
- **Returns the body's result.** The return value of the block is the return value of `handle`.
- **Scoped.** Handlers are pushed onto a stack when `handle` enters and popped when it exits, even if the body throws an exception.

### Multiple effect handlers

Handle multiple effects in a single `handle` block:

```typist
my @logs;
my $state = 0;

my $result = handle {
    Logger::log("starting");
    State::put(10);
    my $v = State::get();
    Logger::log("val=$v");
    $v;
} Logger => +{
    log => sub ($msg) { push @logs, $msg },
}, State => +{
    get => sub () { $state },
    put => sub ($n) { $state = $n },
};
# $result is 10
```

### Nested handlers

Inner handlers shadow outer handlers for the same effect:

```typist
my @outer_log;
my @inner_log;

handle {
    Console::log("outer-scope");         # goes to outer handler

    handle {
        Console::log("inner-scope");     # goes to inner handler
    } Console => +{
        log => sub ($msg) { push @inner_log, $msg },
    };

    Console::log("outer-again");         # outer handler active again
} Console => +{
    log => sub ($msg) { push @outer_log, $msg },
};

# @outer_log is ("outer-scope", "outer-again")
# @inner_log is ("inner-scope")
```

### Handler cleanup on exceptions

Handlers are always popped when the `handle` block exits, even on exceptions:

```typist
eval {
    handle {
        Console::log("before");
        die "boom\n";
    } Console => +{
        log => sub ($msg) { },
    };
};
# Console handler is gone here -- calling Console::log("test") would die
```

---

## Exception Handling with Exn

`Exn` is a built-in effect with a single operation, `throw`:

```typist
Exn::throw($error)    # equivalent to die $error
```

When a `handle` block includes an `Exn` handler, it catches exceptions from `die` and `Exn::throw`:

```typist
my $result = handle {
    die "something went wrong\n";
    42;    # unreachable
} Exn => +{
    throw => sub ($err) { "recovered from: $err" },
};
# $result is "recovered from: something went wrong\n"
```

Without an `Exn` handler, exceptions propagate normally through `handle`:

```typist
eval {
    handle {
        die "no handler\n";
    } Console => +{
        log => sub ($msg) { },
    };
};
# $@ is "no handler\n"
```

### Combining Exn with other effects

```typist
my @logs;
my $result = handle {
    Console::log("before");
    die "mid-error\n";
    Console::log("after");    # unreachable
    "normal";
} Console => +{
    log => sub ($msg) { push @logs, $msg },
}, Exn => +{
    throw => sub ($err) { "recovered" },
};

# @logs is ("before")
# $result is "recovered"
```

All handlers (Console and Exn) are properly popped after the block completes.

---

## Built-in Effect Labels

Three effect labels are pre-registered by the Prelude:

| Label | Description | Operations |
|-------|-------------|------------|
| `IO` | Standard I/O | None (ambient marker) |
| `Exn` | Exceptions | `throw: (Any) -> Never` |
| `Decl` | Type declarations | None (ambient marker) |

These are **ambient** effects: the static effect checker skips them in inclusion checks. This means:

- A pure function can call `say`, `print`, `warn`, `die`, `eval`, etc. without an effect mismatch.
- You can annotate functions with `![IO]` or `![Exn]` for documentation, but it is not required.

Perl builtins are annotated with their appropriate effects in the Prelude. For example, `say` is `(...Any) -> Bool ![IO]`, `die` is `(...Any) -> Never ![Exn]`, and `eval` is `(Any) -> Any ![Exn]`.

---

## Overriding Builtin Effect Annotations

Use `declare` to override a builtin's effect annotation. This is useful when you want stricter effect tracking:

```typist
# Make say require the Console effect instead of ambient IO
declare say => '(Str) -> Void ![Console]';

sub greet :sig((Str) -> Void ![Console]) ($name) {
    say "Hello, $name";    # OK: Console is declared
}

sub bad :sig((Str) -> Void) ($name) {
    say "Hello, $name";    # EffectMismatch: say requires Console
}
```

---

## Effect Checking Rules

The static effect checker enforces these rules:

### Rule 1: Pure cannot call effectful

An annotated function without effects cannot call a function with non-ambient effects:

```typist
sub effectful :sig((Str) -> Str ![Console]) ($x) { $x }

sub pure_fn :sig((Str) -> Str) ($x) {
    effectful($x);    # EffectMismatch: pure_fn() has no effect annotation
}
```

### Rule 2: Callee effects must be a subset of caller effects

```typist
sub needs_ab :sig(() -> Void ![A, B]) () { ... }

sub has_a :sig(() -> Void ![A]) () {
    needs_ab();    # EffectMismatch: missing effect 'B'
}

sub has_abc :sig(() -> Void ![A, B, C]) () {
    needs_ab();    # OK: {A, B} is a subset of {A, B, C}
}
```

### Rule 3: Unannotated callers are skipped

Unannotated functions are not checked for effects. This is the gradual typing principle:

```typist
sub helper ($x) {
    effectful($x);    # No check -- helper is unannotated
}
```

### Rule 4: Unannotated callees are treated as pure

When an annotated function calls an unannotated function, the callee is treated as having no effects:

```typist
sub helper ($x) { $x }    # unannotated -- treated as pure

sub main :sig((Str) -> Str ![Console]) ($s) {
    helper($s);    # OK: helper is pure
}
```

### Suppressing diagnostics

Use `# @typist-ignore` on the line before a call to suppress effect mismatch diagnostics:

```typist
sub pure_fn :sig((Str) -> Str) ($s) {
    # @typist-ignore
    effectful($s);    # No EffectMismatch reported
    $s;
}
```

---

## A Complete Example

```typist
use v5.40;
use Typist;

BEGIN {
    effect Console => +{
        writeLine => '(Str) -> Void',
        readLine  => '() -> Str',
    };

    effect State => +{
        get => '() -> Int',
        put => '(Int) -> Void',
    };
}

sub increment :sig(() -> Int ![State]) () {
    my $n = State::get();
    State::put($n + 1);
    $n + 1;
}

sub run :sig(() -> Void ![Console, State]) () {
    Console::writeLine("Count: " . increment());
    Console::writeLine("Count: " . increment());
    Console::writeLine("Count: " . increment());
}

# Wire up the handlers and execute
my $counter = 0;
handle {
    run();
} Console => +{
    writeLine => sub ($msg) { say $msg },
    readLine  => sub ()     { <STDIN> =~ s/\n\z//r },
}, State => +{
    get => sub () { $counter },
    put => sub ($n) { $counter = $n },
};

# Output:
#   Count: 1
#   Count: 2
#   Count: 3
```

---

## Summary

| Concept | Syntax |
|---------|--------|
| Define effect | `effect Name => +{ op => 'sig', ... }` |
| Call operation | `Name::op(args)` |
| Annotate effects | `:sig((Params) -> Return ![E1, E2])` |
| Handle effects | `handle { body } E => +{ op => sub { ... } }` |
| Catch exceptions | `handle { body } Exn => +{ throw => sub ($e) { ... } }` |
| Override builtin | `declare say => '(Str) -> Void ![Console]'` |
| Suppress check | `# @typist-ignore` |

**Next**: [Effect Protocols](effect-protocols.md) -- add state machine verification to your effects.
