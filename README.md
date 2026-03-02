# Typist

A pure Perl type system for Perl 5.40+.

Typist brings static type annotations to Perl through standard attribute syntax. Errors are caught at compile time (CHECK phase) and via LSP — no source filters, no external tooling, no runtime cost by default.

```
                  `:sig(...)` attribute
                        |
      +----------+------+------+----------+
      |          |             |           |
  CHECK phase  CLI Check   LSP Server  Runtime (opt-in)
  (compile)    (terminal)  (editor)    (-runtime flag)
      |          |             |           |
  warn STDERR  exit code   Diagnostics  die on mismatch
```

## Synopsis

```perl
use Typist qw(Int Str Num Bool Double ArrayRef HashRef Record Maybe optional);

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
my $count :sig(Int) = 0;
my $label :sig(Maybe[Str]) = undef;

# Typed subroutines — unified :sig() annotation
sub add :sig((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

# Generics with bounded quantification
sub max_of :sig(<T: Num>(T, T) -> T) ($a, $b) {
    $a > $b ? $a : $b;
}

# Algebraic effects with row polymorphism
BEGIN {
    effect Console => +{
        readLine  => '() -> Str',
        writeLine => '(Str) -> Void',
    };
}

sub greet :sig((Str) -> Str ![Console]) ($name) {
    "Hello, $name!";
}

# Row polymorphism — "at least Log, plus whatever r adds"
sub with_log :sig(<r: Row>(Str) -> Str ![Log, r]) ($msg) {
    $msg;
}
```

## Features

### Type System

| Feature | Syntax | Example |
|---------|--------|---------|
| Primitive types | `Int`, `Str`, `Double`, `Num`, `Bool`, `Any`, `Void`, `Never`, `Undef` | `my $x :sig(Int) = 42` |
| Parameterized types | `Name[T, ...]` | `ArrayRef[Int]` (`Array[Int]`), `HashRef[Str, Int]` (`Hash[Str, Int]`) |
| Union / Intersection | `A \| B`, `A & B` | `Int \| Str`, `Readable & Writable` |
| Function types | `(A, B) -> R` | `(Int, Int) -> Int` |
| Struct (nominal) | `struct Name => (fields)` | Blessed immutable objects with accessors |
| Record (structural) | `{ k => T, k? => T }` | `{ name => Str, age? => Int }` |
| Maybe | `Maybe[T]` | `Maybe[Str]` = `Str \| Undef` |
| Literal types | `42`, `"hello"` | Singleton types for specific values |
| Type aliases | `typedef` | `typedef Price => Int` |
| Nominal types | `newtype` / `->base` | `newtype UserId => Int` |
| ADT / GADT | `datatype` | Tagged unions, per-constructor return types |
| Enumerations | `enum` | `enum Color => qw(Red Green Blue)` |
| Generics | `<T>`, `<T: Bound>` | `<T: Num>(T, T) -> T` |
| Rank-2 polymorphism | `forall` | `forall A. (A) -> A` |
| Variadic functions | `...Type` | `(Int, ...Str) -> Void` |
| Type classes / HKT | `typeclass` / `instance` | Ad-hoc polymorphism, `F: * -> *` |
| Algebraic effects | `effect` / `![...]` | `![Console, Log]` |
| Effect protocols | `protocol('From -> To')` | `![DB<None -> Authed>]` |
| Row polymorphism | `<r: Row>` / `[E, r]` | Effect row extension |
| Effect handlers | `Effect::op(...)` / `handle` | Direct dispatch + scoped handling |

### Analysis

| Feature | Description |
|---------|-------------|
| CHECK-phase analysis | Type/effect errors at compile time via `warn` |
| CLI checker | Terminal-based static analysis with colored output |
| LSP server | Hover, completion, diagnostics, go-to-definition, references, rename, code actions, semantic tokens, and more |
| Cross-file checking | Workspace-level type resolution across modules |
| Gradual typing | Annotation density determines check strictness |
| Type inference | Bidirectional inference, control flow narrowing (`defined`, truthiness, `isa`, early return) |
| Builtin prelude | 80 builtins with type annotations and three standard effect labels (`IO`, `Exn`, `Decl`) |

### Modes

| Mode | Cost | Behavior |
|------|------|----------|
| Static-only (default) | Zero runtime overhead | `warn` diagnostics at CHECK phase |
| Runtime (`-runtime`) | Per-call type checks via `tie` + sub wrapping | `die` on type violation |
| Newtype boundary | Always active | Constructor validation regardless of mode |

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
make install  # Installs typist-check and typist-lsp
```

## CLI Tools

### typist-check

Static type checker for the terminal. Uses the same analysis engine as the LSP server.

```sh
typist-check                         # Scan lib/ for .pm files
typist-check lib/Shop/Order.pm       # Check specific file(s)
typist-check --root src/             # Custom workspace root
typist-check --no-color              # Disable colored output
typist-check --verbose               # Show clean files too
```

Output example:

```
lib/Shop/Order.pm
  42:5    error    expected Int, got Str in argument 1  [TypeMismatch]
  58:1    error    wrong number of arguments             [ArityMismatch]

lib/Shop/Payment.pm
  17:1    warning  undeclared type variable 'T'          [UndeclaredTypeVar]

2 error(s), 1 warning(s) in 2 file(s) (4 files checked)
```

Exit codes: `0` = clean, `1` = errors, `2` = warnings only.

Color is disabled automatically when stdout is not a TTY, `--no-color` is passed, or `NO_COLOR` is set.

## Annotation Syntax

Typist uses a single unified `:sig(...)` attribute for all type annotations.

### Variables

```perl
my $x :sig(Int) = 42;
my $y :sig(Str | Undef) = undef;
my $z :sig({ name => Str, age => Int }) = { name => "Alice", age => 30 };
```

### Functions

```perl
# Parameters and return type
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }

# With effects
sub greet :sig((Str) -> Str ![Console]) ($name) { "Hello, $name!" }

# With generics
sub first :sig(<T>(ArrayRef[T]) -> T) ($arr) { $arr->[0] }

# With bounded quantification
sub max_of :sig(<T: Num>(T, T) -> T) ($a, $b) { $a > $b ? $a : $b }

# Variadic arguments
sub log_all :sig((Str, ...Any) -> Void ![Console]) ($fmt, @args) { }
```

### Struct Types (Nominal)

```perl
BEGIN {
    struct Person => (
        name  => Str,
        age   => Int,
        email => optional(Str),   # omittable field
    );
}

my $p = Person(name => "Alice", age => 30);
$p->name;                    # "Alice"
$p->with(age => 31);         # immutable update
```

Struct types are **nominal**: `Struct <: Record` (structural compatibility), but `Record </: Struct` (nominal barrier).

### Nominal Types (Newtype)

```perl
BEGIN {
    newtype UserId  => 'Int';
    newtype Email   => 'Str';
}

my $uid = UserId(42);       # Constructor validates inner type
my $raw = $uid->base;       # Extracts inner value: 42
```

### Algebraic Data Types

```perl
BEGIN {
    datatype Shape =>
        Circle    => '(Int)',
        Rectangle => '(Int, Int)',
        Point     => '';

    enum Color => qw(Red Green Blue);   # Nullary-only ADT
}

my $c = Circle(5);          # Auto-generated constructor
```

GADT constructors specify per-constructor return types:

```perl
BEGIN {
    datatype 'Expr[A]' =>
        IntLit  => '(Int) -> Expr[Int]',
        BoolLit => '(Bool) -> Expr[Bool]',
        Add     => '(Expr[Int], Expr[Int]) -> Expr[Int]';
}
```

### Effects and Handlers

```perl
BEGIN {
    effect Console => +{
        readLine  => '() -> Str',
        writeLine => '(Str) -> Void',
    };
}

# Function declares its effects
sub io_greet :sig((Str) -> Void ![Console]) ($name) { say "Hi, $name" }

# Effect operations are called as qualified subs
Console::writeLine("hello");

# handle installs scoped handlers and executes a body
my $result = handle {
    Console::writeLine("start");
    42;
} Console => +{
    writeLine => sub ($msg) { say $msg },
};
```

### Effect Protocols (Stateful Effects)

Effects can carry protocol state machines that enforce operation ordering:

```perl
BEGIN {
    # Quote the name when using comma syntax (strict subs)
    effect 'Database', [qw(None Connected Authed)] => +{
        connect => ['(Str) -> Void',      protocol('None -> Connected')],
        auth    => ['(Str, Str) -> Void', protocol('Connected -> Authed')],
        query   => ['(Str) -> Str',       protocol('Authed -> Authed')],
    };
}

# State transitions are declared in type annotations
sub setup :sig(() -> Void ![Database<None -> Authed>]) () {
    Database::connect("localhost");  # None → Connected
    Database::auth("user", "pass");  # Connected → Authed
}

# Invariant state: start and end in the same state
sub run_query :sig((Str) -> Str ![Database<Authed>]) ($sql) {
    Database::query($sql);           # Authed → Authed
}
```

The static analyzer traces operation sequences and verifies that the final state matches the declared end state. Calling `DB::query` from state `None` produces a `ProtocolMismatch` diagnostic.

### Type Classes

```perl
BEGIN {
    typeclass Show => T, +{
        show => '(T) -> Str',
    };

    instance Show => Int, +{
        show => sub ($x) { "$x" },
    };
}

say Show::show(42);      # "42"
```

### Declare and Suppress

```perl
# Annotate external functions for type/effect checking
declare say => '(Str) -> Void ![Console]';

sub handler :sig((Str) -> Str ![Console]) ($s) {
    # @typist-ignore
    some_unannotated_function($s);  # Diagnostic suppressed
}
```

## Gradual Typing

Typist enforces checks proportional to annotation density:

| Annotation Level | Type Checks | Effect Checks |
|------------------|-------------|---------------|
| Fully annotated | All params, return, call sites | Full effect inclusion |
| Partially annotated (no return) | Params only, return type unknown | As declared |
| Partially annotated (no `:Eff`) | As declared | Treated as pure |
| Completely unannotated | Skipped (`Any -> Any`) | Treated as `[*]` — flags in callers |

## Editor Integration

### LSP Server

The standalone LSP server provides a comprehensive editing experience:

| Capability | Description |
|------------|-------------|
| Diagnostics | Type mismatch, arity mismatch, effect mismatch, alias cycles |
| Hover | Type signatures for functions, variables, constructors, typedefs |
| Completion | Type annotation completion and type-aware code completion |
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

A dedicated extension is provided at `editors/vscode/`.

Build and install:

```sh
cd editors/vscode
npm install
npm run build
npx vsce package
code --install-extension typist-0.0.1.vsix
```

The extension looks for `local/bin/typist-lsp` in the workspace root (e.g. installed via `cpanm -L local Typist`), then falls back to `typist-lsp` on `$PATH`. To override, set `typist.server.path` in VS Code settings.

### Perl::Critic Policies

Four policies for code quality enforcement:

| Policy | Description | Default Severity |
|--------|-------------|-----------------|
| `Typist::TypeCheck` | Static type checking via Typist analyzer | 2 |
| `Typist::AnnotationStyle` | Require `:sig()` on public subs | 2 |
| `Typist::EffectCompleteness` | Require effect declarations for effectful functions | 3 |
| `Typist::ExhaustivenessCheck` | Warn on non-exhaustive `match` expressions | 2 |

```ini
# .perlcriticrc
[Typist::TypeCheck]
severity = 2

[Typist::AnnotationStyle]
severity = 2

[Typist::EffectCompleteness]
severity = 3

[Typist::ExhaustivenessCheck]
severity = 2
```

## Environment Variables

| Variable | Effect |
|----------|--------|
| `TYPIST_RUNTIME` | Enable runtime enforcement (`1` = on) |
| `TYPIST_CHECK_QUIET` | Suppress CHECK-phase diagnostics (`1` = quiet) |
| `TYPIST_LSP_LOG` | LSP log level (`off`/`error`/`warn`/`info`/`debug`/`trace`) |
| `TYPIST_LSP_TRACE` | Path to JSONL trace file for LSP message recording |
| `NO_COLOR` | Disable colored output in `typist-check` |

## Examples

See `example/` for runnable demonstrations:

| File | Topics |
|------|--------|
| `01_foundations.pl` | Type aliases, typed variables/functions |
| `02_composite_types.pl` | Struct, Union, Maybe, parameterized types |
| `03_generics.pl` | Generic functions, bounded quantification |
| `04_nominal_types.pl` | Newtypes, literal types, recursive types |
| `05_algebraic_types.pl` | Datatype/ADT, pattern matching, enum |
| `06_typeclasses.pl` | Type classes, HKT, Functor |
| `07_effects.pl` | Effect system, handlers, protocols |
| `08_gradual_typing.pl` | Gradual typing, flow typing |
| `09_dsl.pl` | DSL operators, constructors |
| `10_higher_order.pl` | Higher-order function inference |
| `11_static_errors.pl` | Intentional type errors for static analysis demo |
| `12_method_chains.pl` | Struct accessors, immutable updates, newtype chains |

```sh
carton exec -- perl example/01_foundations.pl
```

## Testing

```sh
# All tests (65 files)
carton exec -- prove -l t/ t/static/ t/lsp/ t/critic/

# By category
carton exec -- prove -l t/              # Core type system
carton exec -- prove -l t/static/       # Static analysis
carton exec -- prove -l t/lsp/          # LSP server
carton exec -- prove -l t/critic/       # Perl::Critic policy
```

## Known Limitations

- **Expression inference** — Complex dereference chains (`$a->{k}[0]{j}`) may widen to `Any`. Operator precedence does not influence inferred types.
- **Method checking** — Only `$self->method()` within the same package is checked. Cross-package and chained method calls are skipped under gradual typing.
- **Type narrowing** — Supports `defined($x)`, truthiness, `isa`, and early return. Does not support `ref()` checks or user-defined predicates.
- **Effect system** — Effects require explicit annotations; there is no effect inference. Row-polymorphic verification is limited. Protocol checking traces linear operation sequences; branching control flow within effectful functions is not yet tracked.
- **Cross-file CHECK** — The CHECK phase is single-file. Use `TYPIST_CHECK_QUIET=1` with the LSP or CLI for cross-file diagnostics.
- **Hover** — Builtin and special-form hovers show static Prelude signatures, not call-site-specific inferred types.
- **PPI dependency** — Diagnostic quality depends on PPI's parse accuracy.

## License

MIT License. See [LICENSE](LICENSE) for details.
