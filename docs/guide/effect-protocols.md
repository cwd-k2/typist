# Effect Protocols

Effect protocols add state machine verification to algebraic effects. Each operation has a pre-state and a post-state, and the static checker verifies that operations are called in a valid sequence. This catches protocol violations -- like querying a database before authenticating, or disconnecting twice -- at compile time.

---

## When to Use Protocols

Use protocols when your effect operations have sequencing constraints:

- Database connections: connect before auth, auth before query, disconnect when done.
- File handles: open before read/write, close when done.
- Transaction managers: begin before commit/rollback.
- Network protocols: handshake before data exchange, finalize before close.

Without protocols, the effect system only tracks *which* effects a function uses. With protocols, it also tracks *how* the effect transitions through states.

---

## Defining a Protocol Effect

The three-argument form of `effect` defines an effect with protocol states:

```perl
use v5.40;
use Typist;

BEGIN {
    effect DB => qw/Connected Authed/ => +{
        connect    => protocol('(Str) -> Void',         '* -> Connected'),
        auth       => protocol('(Str, Str) -> Void',    'Connected -> Authed'),
        query      => protocol('(Str) -> Str',          'Authed -> Authed'),
        disconnect => protocol('() -> Void',            'Connected | Authed -> *'),
    };
}
```

The three arguments to `effect`:

1. **Name** -- the effect name (auto-quoted by `=>`).
2. **States** -- declared state names as a `qw//` list. These are the active states the protocol can be in. The ground state `*` is implicit and does not need to be listed.
3. **Operations hashref** -- maps operation names to `protocol()` values.

### The `protocol()` function

Each operation uses `protocol()` to combine its type signature with its state transition:

```perl
protocol('(ArgTypes) -> ReturnType', 'FromState -> ToState')
```

- **First argument**: the operation's type signature, same syntax as `:sig()`.
- **Second argument**: the state transition string, `FromState -> ToState`.

### State symbols

| Symbol | Meaning |
|--------|---------|
| `*` | Ground state -- the protocol is inactive (session not started or fully complete) |
| `StateName` | A specific named state from the declared states list |
| `A \| B` | Superposition -- the operation is valid when in either state A or state B |

---

## How Protocols Work

A protocol defines a finite state machine. Each operation is a transition edge:

```
                    connect
        *  ─────────────────>  Connected
                                  │
                          auth    │
                                  v
                               Authed ──┐
                                  │     │ query
                                  │<────┘
                                  │
        *  <──────────────────────┘
                  disconnect
           (from Connected | Authed)
```

When the static checker analyzes a function, it:

1. Starts from the declared initial state.
2. Steps through each effect operation in the function body.
3. Checks that each operation is valid from the current state.
4. Transitions to the operation's post-state.
5. Verifies that the final state matches the declared end state.

---

## Annotating Protocol Effects on Functions

Protocol state annotations appear inside the effect row brackets using `<From -> To>` syntax:

```perl
# Starts from ground, ends at Connected
sub start_db :sig((Str) -> Void ![DB<* -> Connected>]) ($dsn) {
    DB::connect($dsn);
}

# Stays in Authed (invariant)
sub run_query :sig((Str) -> Str ![DB<Authed -> Authed>]) ($sql) {
    DB::query($sql);
}

# Short form for invariant: single state
sub run_query2 :sig((Str) -> Str ![DB<Authed>]) ($sql) {
    DB::query($sql);
}

# Full session: ground to ground
sub with_db :sig((Str, Str) -> Str ![DB<* -> *>]) ($dsn, $sql) {
    DB::connect($dsn);
    DB::auth("admin", "secret");
    my $r = DB::query($sql);
    DB::disconnect();
    $r;
}
```

### Annotation variants

| Annotation | Meaning |
|------------|---------|
| `![DB<* -> Connected>]` | Starts from ground, ends at Connected |
| `![DB<Authed -> Authed>]` | Stays in Authed (idempotent operations) |
| `![DB<Authed>]` | Shorthand for `Authed -> Authed` |
| `![DB<* -> *>]` | Full session -- must start and end at ground |
| `![DB]` | Defaults to `* -> *` -- full session |

The bare `![DB]` form (no angle brackets) defaults to `* -> *`, meaning the function must complete a full protocol cycle, returning the effect to its ground state.

---

## Protocol Errors

### Operation not allowed in current state

```perl
sub bad :sig(() -> Void ![DB<* -> Authed>]) () {
    DB::query("SELECT 1");    # ProtocolMismatch: 'query' not allowed in state '*'
}
```

The `query` operation requires the `Authed` state, but the function starts at `*`.

### Wrong end state

```perl
sub partial :sig(() -> Void ![DB<* -> Authed>]) () {
    DB::connect("localhost");
    # ProtocolMismatch: ends in state 'Connected' but declared end state is 'Authed'
}
```

The function declares it will end at `Authed`, but only reaches `Connected`.

### Incomplete session

```perl
sub incomplete :sig(() -> Void ![DB]) () {
    DB::connect("localhost");
    DB::auth("user", "pass");
    # ProtocolMismatch: ends in state 'Authed' but declared end state is '*'
}
```

`![DB]` defaults to `* -> *`, but the function never disconnects.

---

## Composing Functions with Protocols

Functions with protocol annotations can call each other. The checker tracks the state transition across the call:

```perl
sub do_connect :sig(() -> Void ![DB<* -> Connected>]) () {
    DB::connect("localhost");
}

sub full_setup :sig(() -> Void ![DB<* -> Authed>]) () {
    do_connect();                     # state: * -> Connected
    DB::auth("user", "pass");         # state: Connected -> Authed
}
```

The checker knows that `do_connect()` transitions `DB` from `*` to `Connected`, so the subsequent `DB::auth` call is valid.

---

## Branching

The protocol checker handles control flow:

### Convergent branches

Both branches must reach the same state:

```perl
sub setup :sig((Bool) -> Void ![DB<* -> Connected>]) ($flag) {
    if ($flag) {
        DB::connect("host1");     # * -> Connected
    } else {
        DB::connect("host2");     # * -> Connected
    }
    # Both branches end at Connected -- OK
}
```

### Divergent branches produce errors

```perl
sub bad_branch :sig((Bool) -> Void ![DB<* -> Authed>]) ($flag) {
    DB::connect("localhost");         # * -> Connected
    if ($flag) {
        DB::auth("user", "pass");     # Connected -> Authed
    } else {
        DB::disconnect();             # Connected -> *
    }
    # ProtocolMismatch: branches end in {Authed | *}, not Authed
}
```

### Early return

A branch that returns is excluded from the state union:

```perl
sub early_return :sig((Bool) -> Void ![DB<* -> Authed>]) ($flag) {
    DB::connect("localhost");         # * -> Connected
    if ($flag) {
        return;                       # exits function -- excluded from union
    } else {
        DB::auth("user", "pass");     # Connected -> Authed
    }
    # Only the else branch contributes to the final state -- OK
}
```

### If without else

An `if` without `else` creates a fallthrough path where no state change occurs:

```perl
sub maybe_connect :sig((Bool) -> Void ![DB<* -> Connected>]) ($flag) {
    if ($flag) {
        DB::connect("localhost");     # * -> Connected
    }
    # Fallthrough: state remains * (no else branch)
    # Union of {Connected, *} does not match Connected -- ProtocolMismatch
}
```

---

## Loops

Protocol operations inside loops must be **idempotent** -- the loop body must not change the protocol state. This is because the loop may execute any number of times, and the checker cannot reason about iteration counts:

```perl
# OK: query is Authed -> Authed (idempotent)
sub query_loop :sig(() -> Void ![DB<Authed>]) () {
    while (1) {
        DB::query("SELECT 1");     # Authed -> Authed
    }
}

# Error: disconnect changes state
sub bad_loop :sig(() -> Void ![DB<Connected>]) () {
    for my $i (1..3) {
        DB::disconnect();          # Connected -> * (not idempotent!)
    }
    # ProtocolMismatch: loop body changes state from 'Connected' to '*'
}
```

---

## Superposition States

An operation can accept multiple pre-states using the `|` operator:

```perl
disconnect => protocol('() -> Void', 'Connected | Authed -> *'),
```

This means `disconnect` is valid when the protocol is in either `Connected` or `Authed`. After a conditional branch that leaves the state as a union, an operation with a matching superposition from-set can resolve the ambiguity:

```perl
sub diverge_then_disconnect :sig((Bool) -> Void ![DB<* -> *>]) ($flag) {
    DB::connect("localhost");          # * -> Connected
    if ($flag) {
        DB::auth("user", "pass");      # Connected -> Authed
    }
    # State is {Connected | Authed} (union from if without else)
    DB::disconnect();                  # {Connected | Authed} -> *  -- OK
}
```

The `disconnect` operation's from-set `{Connected, Authed}` is a superset of the current state set `{Connected, Authed}`, so the transition is valid. The result state is `*`.

---

## Match Arms

`match` expressions are treated similarly to if/else branches. Each arm is traced independently, and the results are unioned:

```perl
sub match_ops :sig((Str) -> Void ![DB<Connected -> Authed>]) ($mode) {
    match $mode,
        admin => sub { DB::auth("admin", "secret") },    # Connected -> Authed
        user  => sub { DB::auth("user", "pass") };        # Connected -> Authed
    # Both arms reach Authed -- OK
}
```

Divergent match arms produce a `ProtocolMismatch`:

```perl
sub bad_match :sig((Str) -> Void ![DB<Connected -> Authed>]) ($mode) {
    match $mode,
        admin => sub { DB::auth("admin", "secret") },    # Connected -> Authed
        guest => sub { DB::disconnect() };                # Connected -> *
    # ProtocolMismatch: arms end in {Authed | *}, not Authed
}
```

---

## Handle Blocks and Protocols

When a `handle` block captures the same effect as the protocol being traced, the body is traced with a fresh `* -> *` scope:

```perl
sub with_handle :sig(() -> Void ![DB<* -> *>]) () {
    handle {
        DB::connect("localhost");
        DB::auth("user", "pass");
        DB::query("SELECT 1");
        DB::disconnect();
    } DB => +{
        connect    => sub ($host)   { },
        auth       => sub ($u, $p)  { },
        query      => sub ($sql)    { "mock" },
        disconnect => sub ()        { },
    };
}
```

When a `handle` block captures a *different* effect, it is transparent to the protocol being traced:

```perl
sub transparent :sig(() -> Void ![DB<* -> Authed>, Logger]) () {
    handle {
        DB::connect("localhost");     # protocol operations traced normally
        DB::auth("user", "pass");
    } Logger => +{ log => sub ($msg) { } };
    # Logger handler does not affect DB protocol tracing
}
```

---

## Well-Formedness Checks

The analyzer performs well-formedness checks on protocol definitions:

### Unreachable operations

An operation that appears in the effect but not in any protocol transition is flagged:

```perl
effect BadDB => qw/None Connected/ => +{
    connect   => protocol('(Str) -> Void', 'None -> Connected'),
    query     => protocol('(Str) -> Str',  'Connected -> Connected'),
    orphan_op => '() -> Void',    # not part of any transition
};
# ProtocolMismatch: operation 'orphan_op' unreachable from any protocol state
```

### Undeclared target states

A transition target that is not in the declared states list is flagged:

```perl
effect BadDB => qw/None/ => +{
    connect => protocol('(Str) -> Void', 'None -> Connected'),
};
# ProtocolMismatch: state 'Connected' not in the declared states list
```

---

## A Complete Example

```perl
use v5.40;
use Typist;

BEGIN {
    effect Register => qw/Scanning Paying/ => +{
        open_reg => protocol('() -> Void',                     '* -> Scanning'),
        scan     => protocol('(Str, Int) -> Void',             'Scanning -> Scanning'),
        pay      => protocol('(Str) -> Bool',                  'Scanning -> Paying'),
        complete => protocol('() -> Int',                       'Paying -> *'),
    };
}

# Full checkout session: * -> Scanning -> ... -> Paying -> *
sub checkout :sig((ArrayRef[Str]) -> Int ![Register]) ($items) {
    Register::open_reg();
    for my $item (@$items) {
        Register::scan($item, 1);        # idempotent: Scanning -> Scanning
    }
    Register::pay("cash");
    Register::complete();
}

# Partial: only the scanning phase
sub scan_items :sig((ArrayRef[Str]) -> Void ![Register<Scanning>]) ($items) {
    for my $item (@$items) {
        Register::scan($item, 1);
    }
}

# Runtime: provide handler implementations
my @receipt;
my $total = 0;

my $result = handle {
    checkout(["apple", "bread", "milk"]);
} Register => +{
    open_reg => sub ()         { @receipt = (); $total = 0 },
    scan     => sub ($item, $qty) { push @receipt, "$qty x $item"; $total += $qty * 100 },
    pay      => sub ($method)  { say "Payment: $method"; 1 },
    complete => sub ()         { say "Receipt: " . join(", ", @receipt); $total },
};

say "Total: $result";
```

---

## Summary

| Concept | Syntax |
|---------|--------|
| Define protocol effect | `effect Name => qw/States/ => +{ op => protocol('sig', 'transition'), ... }` |
| Transition syntax | `'FromState -> ToState'` |
| Superposition | `'A \| B -> C'` |
| Ground state | `*` (protocol inactive) |
| Full session annotation | `![Effect]` or `![Effect<* -> *>]` |
| Partial annotation | `![Effect<From -> To>]` |
| Invariant annotation | `![Effect<State>]` |

**Previous**: [Algebraic Effects](effects.md) -- the foundation of the effect system.
**Next**: [Gradual Typing](gradual-typing.md) -- annotate at your own pace.
