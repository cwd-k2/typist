# Typist

A pure Perl type system for Perl 5.40+.

Typist brings static type annotations to Perl through standard attribute syntax. Errors are caught at compile time (CHECK phase) and via LSP — no source filters, no external tooling, no runtime cost by default.

```
                  `:Type(...)` attribute
                        |
      +-----------------+-----------------+
      |                 |                 |
  CHECK phase       LSP Server     Runtime (opt-in)
  (compile-time)    (editor)       (-runtime flag)
      |                 |                 |
  warn to STDERR   Diagnostics     die on mismatch
```

## Synopsis

```perl
use Typist;
use Typist::DSL;

# Type aliases and records (structural)
BEGIN {
    typedef Name   => Str;
    typedef Config => Record(host => Str, port => Int);
}

# Nominal struct types (blessed, immutable)
BEGIN {
    struct Person => (name => Str, age => Int, email => optional(Str));
}

my $p = Person(name => "Alice", age => 30);
$p->name;                           # getter
$p->with(age => 31);                # immutable update

# Typed variables
my $count :Type(Int) = 0;
my $label :Type(Maybe[Str]) = undef;

# Typed subroutines — unified :Type() annotation
sub add :Type((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

# Generics with bounded quantification
sub max_of :Type(<T: Num>(T, T) -> T) ($a, $b) {
    $a > $b ? $a : $b;
}

# Algebraic effects with row polymorphism
BEGIN {
    effect Console => +{
        readLine  => '() -> Str',
        writeLine => '(Str) -> Void',
    };
}

sub greet :Type((Str) -> Str !Eff(Console)) ($name) {
    "Hello, $name!";
}

# Row polymorphism — "at least Log, plus whatever r adds"
sub with_log :Type(<r: Row>(Str) -> Str !Eff(Log | r)) ($msg) {
    $msg;
}
```

## Features

### Type System

| Feature | Syntax | Example |
|---------|--------|---------|
| Primitive types | `Int`, `Str`, `Bool`, `Num`, `Any`, `Void`, `Never`, `Undef` | `my $x :Type(Int) = 42` |
| Parameterized types | `Name[T, ...]` | `ArrayRef[Int]`, `HashRef[Str, Int]` |
| Union types | `A \| B` | `Int \| Str` |
| Intersection types | `A & B` | `Readable & Writable` |
| Function types | `(A, B) -> R` | `(Int, Int) -> Int` |
| Struct types (nominal) | `struct Name => (fields)` | Blessed immutable objects with accessors |
| Record types (structural) | `{ k => T, k? => T }` | `{ name => Str, age? => Int }` |
| Maybe sugar | `Maybe[T]` | `Maybe[Str]` = `Str \| Undef` |
| Literal types | `42`, `"hello"` | Singleton types for specific values |
| Type aliases | `typedef` | `typedef Price => Int` |
| Nominal types | `newtype` / `unwrap` | `newtype UserId => Int` |
| Algebraic data types | `datatype` | Tagged unions with auto-generated constructors |
| Enumerations | `enum` | `enum Color => qw(Red Green Blue)` |
| GADT | `datatype` with `->` | `IntLit => '(Int) -> Expr[Int]'` |
| Recursive types | Self-referential `typedef` | `typedef Json => Str \| Int \| ArrayRef[Json]` |
| Generics | `<T>`, `<T, U>` | `<T>(ArrayRef[T]) -> T` |
| Bounded quantification | `<T: Bound>` | `<T: Num>(T, T) -> T` |
| Rank-2 polymorphism | `forall` | `forall A. (A) -> A` |
| Variadic functions | `...Type` | `(Int, ...Str) -> Void` |
| Type classes | `typeclass` / `instance` | Ad-hoc polymorphism with dispatch |
| Multi-parameter type classes | `typeclass Name => 'T, U'` | `Convertible T, U` with multiple type variables |
| Higher-kinded types | `F: * -> *` | Type constructor abstraction with `F[T]` application |
| Algebraic effects | `effect` / `!Eff(...)` | `!Eff(Console \| Log)` |
| Row polymorphism | `<r: Row>` / `Eff(E \| r)` | Effect row extension |
| Effect handlers | `Effect::op(...)` / `handle` | Direct effect dispatch and scoped handling |

### Analysis

| Feature | Description |
|---------|-------------|
| CHECK-phase analysis | Type/effect errors detected at compile time via `warn` |
| LSP server | Hover, completion, diagnostics, document symbols, go-to-definition, signature help, inlay hints, find references, rename, code actions, semantic tokens |
| Perl::Critic policy | `Typist::TypeCheck` policy bridges static analysis into PerlNavigator |
| Cross-file checking | Workspace-level type resolution across modules |
| Gradual typing | Annotation density determines check strictness |
| Bidirectional type inference | Expected types propagated downward to guide inference of literals and expressions |
| Control flow narrowing | `defined($x)` narrows `Maybe[T]` to `T`; truthiness narrows to non-`Undef`; `isa` narrows to the tested class; early `return` narrows the else branch |
| Arity checking | Argument count mismatch detected as ArityMismatch |
| Expression type inference | Arithmetic (`Num`), comparison (`Bool`), string concat (`Str`), subscript access, ternary (Union/LUB) |
| Variable reassignment tracking | Type mismatch on re-assignment to `:Type`-annotated variables |
| Method type checking | `$self->method()` argument types and arity checked within the same package |
| Generic static type checking | Type variables instantiated from call-site arguments for concrete type verification |
| Builtin prelude | 83 builtins (74 Perl core + 9 Typist) with pre-installed type annotations |

### Architecture

| Mode | Cost | Behavior |
|------|------|----------|
| Static-only (default) | Zero runtime overhead | `warn` diagnostics at CHECK phase |
| Runtime (`-runtime`) | Per-call type checks via `tie` + sub wrapping | `die` on type violation |
| Newtype boundary | Always active | Constructor/unwrap validation regardless of mode |

## Installation

### Requirements

- Perl 5.40+
- [PPI](https://metacpan.org/pod/PPI) (automatically resolved by any of the methods below)

### From GitHub (cpanm)

```sh
cpanm https://github.com/cwd-k2/typist.git
```

### From GitHub (Carton)

Add to your `cpanfile`:

```perl
requires 'Typist', git => 'https://github.com/cwd-k2/typist.git';
```

Then:

```sh
carton install
```

### From source

```sh
git clone https://github.com/cwd-k2/typist.git
cd typist
perl Makefile.PL
make
make test
make install
```

### Development setup

For development with Carton (includes optional dependencies):

```sh
carton install
carton install --with-recommends  # For Perl::Critic integration
```

## Annotation Syntax

Typist uses a single unified `:Type(...)` attribute for all type annotations.

### Variables

```perl
my $x :Type(Int) = 42;
my $y :Type(Str | Undef) = undef;
my $z :Type({ name => Str, age => Int }) = { name => "Alice", age => 30 };
```

### Functions

```perl
# Parameters and return type
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }

# With effects
sub greet :Type((Str) -> Str !Eff(Console)) ($name) { "Hello, $name!" }

# With generics
sub first :Type(<T>(ArrayRef[T]) -> T) ($arr) { $arr->[0] }

# With bounded quantification
sub max_of :Type(<T: Num>(T, T) -> T) ($a, $b) { $a > $b ? $a : $b }

# With generic row variable
sub with_log :Type(<r: Row>(Str) -> Str !Eff(Log | r)) ($msg) { $msg }

# Variadic arguments
sub log_all :Type((Str, ...Any) -> Void !Eff(Console)) ($fmt, @args) { }

# No parameters, no return value
sub noop :Type(() -> Void) () { }
```

### Type Aliases

```perl
BEGIN {
    typedef Name   => 'Str';             # String form
    typedef Name   => Str;               # DSL form (with Typist::DSL)
    typedef Person => '{ name => Str, age => Int }';
    typedef Json   => 'Str | Int | Bool | Undef | ArrayRef[Json] | HashRef[Str, Json]';
}
```

### Struct Types (Nominal)

```perl
use Typist;
use Typist::DSL;

BEGIN {
    struct Person => (
        name  => Str,
        age   => Int,
        email => optional(Str),   # omittable field
    );
}

my $p = Person(name => "Alice", age => 30);  # Constructor validates fields
$p->name;                                     # "Alice" — accessor method
$p->age;                                      # 30
$p->with(age => 31);                          # Immutable update — returns new Person
```

Struct types are **nominal**: `Person` and `Record(name => Str, age => Int)` are distinct types even with identical fields. Struct values are blessed objects with auto-generated constructors, accessors, and `with()` for immutable updates. `Struct <: Record` (structural compatibility), but `Record </: Struct` (nominal barrier).

### Nominal Types (Newtype)

```perl
BEGIN {
    newtype UserId  => 'Int';
    newtype Email   => 'Str';
}

my $uid = UserId(42);       # Constructor validates inner type
my $raw = unwrap($uid);     # Extracts inner value: 42
```

### Algebraic Data Types (Datatype)

```perl
BEGIN {
    datatype Shape =>
        Circle    => '(Int)',
        Rectangle => '(Int, Int)',
        Point     => '';
}

my $c = Circle(5);            # Auto-generated constructor, validates argument types
my $r = Rectangle(3, 4);
my $p = Point();
```

Constructors perform runtime validation: arity is checked and each argument is verified against the declared type. Values are blessed into `Typist::Data::$name` with `_tag` and `_values` fields.

### Enumerations

```perl
BEGIN {
    enum Color => qw(Red Green Blue);
}
# Equivalent to: datatype Color => Red => '', Green => '', Blue => '';
```

### GADT (Generalized Algebraic Data Types)

```perl
BEGIN {
    datatype 'Expr[A]' =>
        IntLit  => '(Int) -> Expr[Int]',
        BoolLit => '(Bool) -> Expr[Bool]',
        Add     => '(Expr[Int], Expr[Int]) -> Expr[Int]';
}
```

Constructors with `->` specify per-constructor return types, enabling type-safe interpreters and expression trees.

### Effects

```perl
BEGIN {
    effect Console => +{
        readLine  => '() -> Str',
        writeLine => '(Str) -> Void',
    };
}

# Function declares its effects
sub io_greet :Type((Str) -> Void !Eff(Console)) ($name) { say "Hi, $name" }

# Caller must declare at least callee's effects
sub main :Type(() -> Void !Eff(Console)) () { io_greet("Alice") }
```

### Effect Handlers (Effect::op / handle)

Effect definitions auto-install qualified subs for each operation. These dispatch to the nearest handler on the runtime stack.

```perl
use Typist -runtime;

BEGIN {
    effect Console => +{
        log => '(Str) -> Void',
    };

    effect State => +{
        get => '() -> Int',
        put => '(Int) -> Void',
    };
}

# Effect operations are called as qualified subs: Effect::op(...)
sub greet :Type((Str) -> Str !Eff(Console)) ($name) {
    Console::log("Hello, $name!");
    "greeted $name";
}

# handle installs scoped handlers, executes a body, then pops them
my $state = 0;
my $result = handle {
    Console::log("start");
    State::put(10);
    State::get();
} Console => +{
    log => sub ($msg) { say $msg },
}, State => +{
    get => sub ()  { $state },
    put => sub ($n) { $state = $n; undef },
};
# $result is 10; handlers are automatically popped after the block
```

Handlers form a LIFO stack. Inner `handle` blocks shadow outer ones for the same effect. Handlers are always popped on normal exit and on exception.

### Type Classes

```perl
use Typist::DSL;

BEGIN {
    typeclass Show => T, +{
        show => '(T) -> Str',
    };

    instance Show => Int, +{
        show => sub ($x) { "$x" },
    };

    instance Show => Str, +{
        show => sub ($x) { qq{"$x"} },
    };
}

say Show::show(42);      # "42"
say Show::show("hello"); # "\"hello\""
```

Multi-parameter type classes support multiple type variables:

```perl
BEGIN {
    typeclass Convertible => 'T, U', +{
        convert => '(T) -> U',
    };

    instance Convertible => 'Int, Str', +{
        convert => sub ($x) { "$x" },
    };
}
```

### Control Flow Narrowing

Typist narrows types inside conditional branches based on the guard expression:

```perl
# defined() narrows Maybe[T] to T
sub safe_length :Type((Maybe[Str]) -> Int) ($s) {
    if (defined $s) {
        # $s narrowed from Str | Undef to Str
        return length($s);
    }
    return 0;
}

# Truthiness narrows union types by removing Undef
sub process :Type((Str | Undef) -> Str) ($s) {
    if ($s) {
        # $s narrowed to Str
        return $s;
    }
    return "default";
}

# Early return narrows the else branch
sub require_str :Type((Maybe[Str]) -> Str) ($s) {
    return "" unless defined $s;
    # $s is Str here (Undef eliminated by early return)
    $s;
}
```

### Method Type Checking

Methods with `$self` as the first parameter are recognized and type-checked within the same package:

```perl
package Calculator;
use Typist;

sub add :Type((Int, Int) -> Int) ($self, $a, $b) {
    $a + $b;
}

sub compute :Type((Int) -> Int) ($self, $n) {
    $self->add($n, $n);  # Argument types and arity checked
}
```

### Declare (External Function Annotations)

```perl
# Annotate builtins or external functions for effect checking
declare say    => '(Str) -> Void !Eff(Console)';
declare length => '(Str) -> Int';                  # Pure builtin
declare die    => '(Any) -> Never !Eff(Abort)';
```

### Suppressing Diagnostics

```perl
sub handler :Type((Str) -> Str !Eff(Console)) ($s) {
    # @typist-ignore
    some_unannotated_function($s);  # No EffectMismatch warning
}
```

## Gradual Typing

Typist enforces checks proportional to annotation density:

| Annotation Level | Type Checks | Effect Checks |
|------------------|-------------|---------------|
| Fully annotated | All params, return, call sites | Full effect inclusion |
| Partially annotated (no return) | Params only, return type unknown | As declared |
| Partially annotated (no `:Eff`) | As declared | Treated as pure |
| Completely unannotated | Skipped (`Any -> Any`) | Treated as `Eff(*)` — flags in callers |

```perl
# Fully annotated — all checks apply
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }

# Partially annotated — params checked, return unknown
sub compute :Type((Int) -> Any) ($n) { $n * $n }

# Unannotated — treated as (Any...) -> Any ! Eff(*)
sub helper ($x) { $x }
```

## Static-First Architecture

By default, `use Typist;` provides **zero runtime overhead**:

```
Compile Time                          Runtime
─────────────────────────────────     ───────────────────
:Type(...) parsed → Registry          Original sub runs
CHECK { Checker → Analyzer }          No wrappers
warn diagnostics → STDERR             No tie overhead
```

### Enabling Runtime Enforcement

```perl
use Typist -runtime;    # Flag in code
# or
TYPIST_RUNTIME=1        # Environment variable
```

Runtime mode adds `tie` to typed scalars and wraps typed subs with validation closures.

### Environment Variables

| Variable | Effect |
|----------|--------|
| `TYPIST_RUNTIME` | Enable runtime enforcement (`1` = on) |
| `TYPIST_CHECK_QUIET` | Suppress CHECK-phase diagnostics (`1` = quiet) |
| `TYPIST_LSP_LOG` | LSP log level (`off`/`error`/`warn`/`info`/`debug`/`trace`) |
| `TYPIST_LSP_TRACE` | Path to JSONL trace file for LSP message recording |

## Editor Integration

### LSP Server

The standalone LSP server provides a comprehensive editing experience:

| Capability | Description |
|------------|-------------|
| Diagnostics | Type mismatch, arity mismatch, effect mismatch, alias cycles |
| Hover | Type signatures for functions, variables, constructors, typedefs |
| Completion | Type annotation completion and type-aware code completion (struct fields, methods, effect operations) |
| Go to Definition | Same-file and cross-file definition lookup |
| Find References | Word-boundary search across open documents and workspace |
| Rename | Symbol rename across all workspace files |
| Signature Help | Function parameter hints with active parameter tracking |
| Document Symbols | Outline of functions, variables, typedefs, newtypes, datatypes, effects, typeclasses |
| Inlay Hints | Inferred types shown inline for unannotated variables |
| Code Actions | Quick-fix suggestions for effect mismatches and type errors |
| Semantic Tokens | Syntax highlighting for Typist keywords, type names, constructors, and type parameters |

Launch the server:

```sh
typist-lsp                            # After make install
carton exec -- perl bin/typist-lsp    # Development (carton)
```

#### Neovim (nvim-lspconfig)

```lua
local configs = require('lspconfig.configs')

configs.typist = {
  default_config = {
    cmd = { 'typist-lsp' },
    filetypes = { 'perl' },
    root_dir = function(fname)
      return vim.fs.dirname(
        vim.fs.find({ 'lib', '.git' }, { upward = true, path = fname })[1]
      )
    end,
  },
}

require('lspconfig').typist.setup {}
```

#### VS Code

Use the `vscode-languageclient` extension:

```json
{
  "typist-lsp.command": "typist-lsp"
}
```

### Perl::Critic Policy (via PerlNavigator)

```ini
# .perlcriticrc
[Typist::TypeCheck]
severity = 2
```

```json
// VS Code settings
{
  "perlnavigator.perlcriticEnabled": true,
  "perlnavigator.perlcriticProfile": ".perlcriticrc"
}
```

## Debugging the LSP Server

### Logging

```sh
TYPIST_LSP_LOG=debug typist-lsp
```

| Level | Output |
|-------|--------|
| `off` | No output |
| `error` | Errors only |
| `warn` | Errors + warnings |
| `info` | Lifecycle events (default) |
| `debug` | Message dispatch, diagnostics |
| `trace` | Full message content |

### Message Tracing

```sh
TYPIST_LSP_TRACE=/tmp/trace.jsonl typist-lsp
```

Each line is a JSON object with direction, timestamp, and message:

```json
{"dir":"recv","ts":"12:34:56.789","msg":{"jsonrpc":"2.0","method":"initialize",...}}
{"dir":"send","ts":"12:34:56.790","msg":{"jsonrpc":"2.0","id":1,"result":{...}}}
```

### Trace Replay

```sh
perl script/lsp-replay trace.jsonl
perl script/lsp-replay --compare trace.jsonl   # Golden-file regression
perl script/lsp-replay --verbose trace.jsonl   # Show each message
```

### Editor Debug Configuration

**Neovim** — redirect stderr to a log file:

```lua
cmd = { 'sh', '-c', 'TYPIST_LSP_LOG=debug typist-lsp 2>/tmp/typist-lsp.log' },
```

**VS Code** — add environment variables to server settings:

```json
{
  "typist-lsp.command": "sh",
  "typist-lsp.args": ["-c", "TYPIST_LSP_LOG=debug TYPIST_LSP_TRACE=/tmp/trace.jsonl typist-lsp 2>/tmp/typist-lsp.log"]
}
```

## Examples

See `example/` for runnable demonstrations:

| File | Topics |
|------|--------|
| `01_foundations.pl` | Type aliases, typed variables/functions, runtime error handling |
| `02_composite_types.pl` | Struct, Union, Maybe, parameterized types |
| `03_generics.pl` | Generic functions, bounded quantification, union types |
| `04_nominal_types.pl` | Newtypes, literal types, recursive types |
| `05_algebraic_types.pl` | Datatype/ADT, pattern matching, enum |
| `06_typeclasses.pl` | Type classes, HKT, Functor |
| `07_effects.pl` | Effect system, perform/handle |
| `08_gradual_typing.pl` | Gradual typing, flow typing |
| `09_dsl.pl` | DSL operators, constructors |
| `lsp/demo.pm` | LSP hover, completion, diagnostic targets |
| `lsp/effects.pm` | LSP effect checking demonstrations |

```sh
carton exec -- perl example/01_foundations.pl
carton exec -- perl example/03_generics.pl
carton exec -- perl example/07_effects.pl
```

## Testing

```sh
# All tests (58 files)
carton exec -- prove -l t/ t/static/ t/lsp/ t/critic/

# By category
carton exec -- prove -l t/              # Core type system (26 files)
carton exec -- prove -l t/static/       # Static analysis (12 files)
carton exec -- prove -l t/lsp/          # LSP server (16 files)
carton exec -- prove -l t/critic/       # Perl::Critic policy (4 files)

# Integration tests
carton exec -- perl t/lsp/e2e_smoke.pl                     # LSP E2E smoke test
carton exec -- perl script/lsp-verify-workspace             # Workspace verification
carton exec -- perl script/lsp-verify-workspace path/to/lib # Custom directory
```

## Known Limitations

### Static Analysis

#### Expression Inference

- String interpolation (`"Hello $name"`), regex matches, and complex dereference chains are
  inferred at a shallow level — intermediate expression types may widen to `Any`.
- Compound arithmetic expressions (`$a + $b * $c`) are treated as a single binary operation;
  operator precedence does not influence the inferred type (always `Num`).

#### Method Checking

- Only `$self->method()` calls within the **same package** are type-checked.
- Cross-package method calls, class method calls (`Foo->bar()`), and chained method calls
  (`$obj->foo->bar`) are skipped under gradual typing rules.

#### Type Narrowing

- Supported: `defined($x)`, truthiness (`if ($x)`), `$x isa Foo`, and early return
  (`return unless defined $x`).
- Not supported: `ref()` checks, pattern match guards, or user-defined type predicates.

#### Effect System

- Effects require explicit `:Type(... ! Eff(...))` annotations — there is no effect inference.
- Open row polymorphism (`:Generic(r: Row)`) is parsed and represented, but static verification
  of row-polymorphic effect signatures is limited.

### LSP Server

#### Hover

- Builtin function hovers display the static Prelude signature (e.g., `unwrap` always shows
  `(Any) -> Any`). Call-site-specific inference results are not reflected.
- `handle`, `match`, `map`, and other special-form inferred return types are similarly not
  shown in hover — only the generic signature is displayed.

#### Cross-File Resolution

- The CHECK phase operates on a single-file scope and cannot resolve Exporter-imported
  functions across packages. Use `TYPIST_CHECK_QUIET=1` with the LSP workspace for
  cross-file diagnostics.

#### Diagnostics

- Diagnostic quality depends on PPI's parse accuracy — unusual spacing or syntax inside
  `:Type()` attributes may cause silent misparses.
- On file save, all open documents are re-diagnosed. This may introduce latency in projects
  with many open files.

### CHECK Phase vs LSP vs Runtime

| Detection target              | CHECK | LSP | Runtime |
|-------------------------------|:-----:|:---:|:-------:|
| Type mismatch (var init)      |   ✓   |  ✓  |    ✓    |
| Type mismatch (call args)     |   ✓   |  ✓  |    ✓    |
| Type mismatch (return)        |   ✓   |  ✓  |    ✓    |
| Arity mismatch                |   ✓   |  ✓  |    ✓    |
| Effect mismatch               |   ✓   |  ✓  |    —    |
| Alias cycle                   |   ✓   |  ✓  |    —    |
| Cross-file resolution         |   —   |  ✓  |    —    |
| Generic instantiation         |   ✓   |  ✓  |    ✓    |
| Newtype boundary enforcement  |   —   |  —  |  ✓ (always) |
| TypeClass constraints         |   —   |  —  |    ✓    |
| Effect handler execution      |   —   |  —  |    ✓    |

### Gradual Typing Caveats

- Calls to **unannotated functions** cause effect checking to be skipped at the call site
  (the callee is assumed `Eff(*)`).
- Partial annotation (`:Type` present but no return type) treats the return as unknown —
  callers that depend on the return value will see `Any` via inference fallback.
- Completely unannotated functions are modeled as `(Any...) -> Any ! Eff(*)` — type checking
  is skipped entirely, and effect checking flags them as potentially effectful.

## Project Structure

```
lib/
  Typist.pm                  Entry point, CHECK phase, exports
  Typist/
    Type.pm                  Abstract base (overloads: |, &, "")
    Type/
      Atom.pm                Primitives (Int, Str, ...) — flyweight pool
      Param.pm               Parameterized (ArrayRef[T], HashRef[K,V])
      Union.pm               A | B — normalized, deduplicated
      Intersection.pm        A & B — normalized, deduplicated
      Func.pm                (A, B) -> R !Eff(E) — with effects
      Record.pm              { key => T, key? => T } — structural, optional fields
      Struct.pm              Nominal struct type node — name + record + package
      Var.pm                 Type variables (T, U, V) — bound + kind
      Alias.pm               typedef references — lazy resolution
      Literal.pm             42, "hello" — singleton types
      Newtype.pm             Nominal wrappers — name-based identity
      Data.pm                Tagged unions (datatype/GADT) — variant constructors
      Quantified.pm          forall A B. body — rank-2 polymorphism
      Row.pm                 Effect rows — sorted labels + tail var
      Eff.pm                 Eff(Row) wrapper
      Fold.pm                map_type (bottom-up), walk (top-down)
    Parser.pm                Recursive-descent type expression parser
    Registry.pm              Type/function/effect/method store (class + instance)
    Subtype.pm               Structural subtype relation + LUB
    Inference.pm             Runtime type inference + unification
    Transform.pm             Type substitution (aliases → vars)
    Struct/Base.pm           Blessed immutable object base (with(), accessors)
    Attribute.pm             :Type() handler, sub wrapping, tie
    DSL.pm                   Type constructors (Int, Str, Func(...), Record(...), optional(), ...)
    Kind.pm                  Kind system (Star, Row, Arrow)
    KindChecker.pm           Kind inference and validation
    TypeClass.pm             Def + Inst + dispatch (single + multi-parameter)
    Effect.pm                Effect definitions with typed operations
    Handler.pm               Runtime effect handler stack (Effect::op/handle)
    Prelude.pm               Builtin function type annotations (83 entries)
    Error.pm                 Error value + Collector (instance-based)
    Error/Global.pm          Singleton error buffer
    Tie/Scalar.pm            Runtime scalar type enforcement
    Static/
      Analyzer.pm            Pipeline coordinator (per-file)
      Extractor.pm           PPI-based annotation extraction
      Checker.pm             Structural checks (cycles, vars, kinds)
      TypeChecker.pm         Type mismatch + arity + assignment + method checks
      EffectChecker.pm       Effect mismatch detection
      Infer.pm               Static type inference from PPI
      Unify.pm               Structural type unification for generics
      Registration.pm        Shared type registration (aliases, structs, datatypes, effects, etc.)
    LSP/
      LSP.pm                 Entry point + exit handling
      Server.pm              Lifecycle, message dispatch
      Transport.pm           JSON-RPC with Content-Length framing
      Document.pm            Per-file analysis cache + query interface
      Workspace.pm           Cross-file registry + scanning
      Hover.pm               Type signature display
      Completion.pm          Type annotation + code completion
      CodeAction.pm          Quick-fix code action generation
      SemanticTokens.pm      Semantic token classification
      Logger.pm              Configurable stderr logging
bin/
  typist-lsp                 LSP server executable
script/
  lsp-replay                 JSONL trace replay tool
  lsp-verify-workspace       Workspace integration verifier
example/                     Runnable demonstrations
t/                           Test suite (56 files)
docs/                        Architecture and type system reference
```

## License

MIT License. See [LICENSE](LICENSE) for details.
