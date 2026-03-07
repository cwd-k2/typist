# Getting Started with Typist

This guide takes you from zero to a working Typist-annotated Perl program. It covers the core concepts you need to write type-safe Perl, run the static checker, and set up editor integration.

> **Prerequisites:** Perl 5.40+ and [PPI](https://metacpan.org/pod/PPI). See [README](../README.md#installation) for installation methods.

---

## Table of Contents

- [Your First Typed Program](#your-first-typed-program)
- [Verifying Your Installation](#verifying-your-installation)
- [The `:sig()` Cheatsheet](#the-sig-cheatsheet)
- [Type Basics](#type-basics)
- [Static vs Runtime Mode](#static-vs-runtime-mode)
- [Using `typist-check`](#using-typist-check)
- [Editor / LSP Setup](#editor--lsp-setup)
- [Common Patterns](#common-patterns)
- [Common Pitfalls](#common-pitfalls)
- [Next Steps](#next-steps)

---

## Your First Typed Program

Create `hello_typist.pl`:

```perl
use v5.40;
use lib 'lib';
use Typist;

sub greet :sig((Str) -> Str) ($name) {
    "Hello, $name!";
}

my $msg :sig(Str) = greet("world");
say $msg;
```

Run it:

```sh
perl hello_typist.pl
```

You'll see `Hello, world!` — and if any type errors exist, Typist reports them as warnings during the CHECK phase (before your program's main body executes):

```
Type error in main: expected Int, got Str in argument 1 of add at line 5.
```

CHECK-phase diagnostics go to STDERR as warnings. Your program still runs (static mode doesn't abort), but the errors tell you exactly what to fix.

---

## Verifying Your Installation

Three quick checks to confirm everything works:

**1. Module loads:**

```sh
perl -e 'use Typist; say "ok"'
```

**2. CLI checker runs:**

```sh
typist-check --help
```

**3. An example runs cleanly:**

```sh
perl example/01_foundations.pl
```

If you installed via Carton, prefix commands with `carton exec --`:

```sh
carton exec -- perl example/01_foundations.pl
```

---

## The `:sig()` Cheatsheet

Typist uses a single annotation syntax for everything: the `:sig()` attribute.

### Variables

```perl
my $count :sig(Int)       = 0;
my $label :sig(Str)       = "hi";
my $maybe :sig(Maybe[Str]) = undef;     # Str | Undef
my $data  :sig({ name => Str, age => Int }) = { name => "A", age => 1 };
```

### Functions

```perl
# Basic
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }

# With effects
sub greet :sig((Str) -> Void ![Console]) ($name) { say $name }

# Generics
sub first :sig(<T>(ArrayRef[T]) -> T) ($arr) { $arr->[0] }

# Bounded generics
sub max_of :sig(<T: Num>(T, T) -> T) ($a, $b) { $a > $b ? $a : $b }

# Typeclass constraint
sub show_it :sig(<T: Show>(T) -> Str) ($x) { Show::show($x) }

# Variadic
sub log_all :sig((Str, ...Any) -> Void) ($fmt, @args) { }
```

### Pattern Summary

| Pattern | Syntax | Example |
|---------|--------|---------|
| Variable | `:sig(Type)` | `my $x :sig(Int) = 0` |
| Function | `:sig((Params) -> Return)` | `sub f :sig((Int) -> Str) ($n) { }` |
| Effects | `:sig((Params) -> Return ![E1, E2])` | `![Console, Log]` |
| Generics | `:sig(<T>(T) -> T)` | `<T>`, `<T: Num>`, `<T: Show>` |
| Variadic | `:sig((Fixed, ...Rest) -> R)` | `(Str, ...Any) -> Void` |

---

## Type Basics

### Atom Hierarchy

```
                Any
              / | \ \
           Str Num  | Void
            |   |   |
            | Double |
            |   |    |
            |  Int  Undef
            |   |
            | Bool
            |
            +--+--+
                |
              Never
```

Key rules:
- `Bool <: Int <: Double <: Num <: Any`
- `Str <: Any` (independent from the numeric branch)
- `Never` is the bottom type (subtype of everything)
- `Void` means "no meaningful return value"

### Compound Types

```perl
# Union — either type
my $id :sig(Int | Str) = 42;

# Maybe — nullable (sugar for T | Undef)
my $opt :sig(Maybe[Str]) = undef;

# ArrayRef / HashRef — parameterized containers
my $nums :sig(ArrayRef[Int]) = [1, 2, 3];
my $map  :sig(HashRef[Str, Int]) = +{ a => 1 };
```

### Record vs Struct

**Records** are structural (shape-based):

```perl
my $r :sig({ name => Str, age => Int }) = { name => "A", age => 1 };
```

**Structs** are nominal (name-based, blessed, immutable):

```perl
BEGIN {
    struct Person => (name => Str, age => Int, optional(email => Str));
}

my $p = Person(name => "Alice", age => 30);
$p->name;                    # "Alice"
Person::derive($p, age => 31);   # immutable derive, returns new Person
```

A Struct is a subtype of its corresponding Record shape (`Struct <: Record`), but not the reverse.

### Generics Basics

Type parameters go in `<>` before the parameter list:

```perl
# T is inferred from the argument
sub identity :sig(<T>(T) -> T) ($x) { $x }

# Bounded: T must be a subtype of Num
sub double :sig(<T: Num>(T) -> T) ($x) { $x * 2 }
```

---

## Static vs Runtime Mode

| | `use Typist` | `use Typist -runtime` |
|---|---|---|
| CHECK-phase analysis | ON | ON |
| CLI / LSP diagnostics | ON | ON |
| Structural checks (arity, fields) | ON | ON |
| Effect / typeclass dispatch | ON | ON |
| **Constructor type validation** | **OFF** | **ON** |
| **Tie::Scalar monitoring** | **OFF** | **ON** |
| Runtime cost | Zero | Per-call / per-assignment checks |

**Default (static-only):**

```perl
use Typist;
```

Enables the type system. Errors are caught at compile time (CHECK phase) and in the editor (LSP). No runtime overhead. Type names in `:sig()` annotations are resolved automatically — no import needed.

**Runtime mode:**

```perl
use Typist -runtime;
```

Adds `Tie::Scalar`-based monitoring: typed variables are checked on every assignment. Violations `die` instead of `warn`.

**DSL values for type expressions:**

```perl
use Typist::DSL qw(Int Str Record optional);
```

Imports type **values** as Perl constants. Use these when building type expressions programmatically in `typedef`, `newtype`, `struct`, etc. These are **not** needed for `:sig()` annotations (which parse type names from strings).

---

## Using `typist-check`

The CLI checker runs the same analysis engine as the LSP server:

```sh
typist-check                         # Scan lib/ for .pm files
typist-check lib/MyApp/Order.pm      # Check specific file(s)
typist-check --root src/             # Custom workspace root
typist-check --no-color              # Disable colored output
typist-check --verbose               # Show clean files too
```

### Reading the Output

```
lib/MyApp/Order.pm
  42:5    error    expected Int, got Str in argument 1  [TypeMismatch]
  58:1    error    wrong number of arguments             [ArityMismatch]

lib/MyApp/Payment.pm
  17:1    warning  undeclared type variable 'T'          [UndeclaredTypeVar]

2 error(s), 1 warning(s) in 2 file(s) (4 files checked)
```

- Format: `line:col  severity  message  [DiagnosticKind]`
- Exit codes: `0` = clean, `1` = errors, `2` = warnings only

### CI Integration

```yaml
# GitHub Actions example
- name: Type check
  run: typist-check --no-color
```

Color is disabled automatically when stdout is not a TTY, `--no-color` is passed, or `NO_COLOR` is set.

---

## Editor / LSP Setup

The `typist-lsp` server provides hover, completion, diagnostics, go-to-definition, find references, rename, signature help, inlay hints, code actions, and semantic tokens.

### Neovim (nvim-lspconfig)

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

### VS Code

A dedicated extension is provided at `editors/vscode/`:

```sh
cd editors/vscode
npm install && npm run build
npx vsce package
code --install-extension typist-0.0.1.vsix
```

The extension looks for `local/bin/typist-lsp` in the workspace root, then falls back to `typist-lsp` on `$PATH`. Override with the `typist.server.path` setting.

### What You Get

| Feature | What it does |
|---------|-------------|
| Diagnostics | Type/effect/arity errors as you type |
| Hover | Type signatures on hover |
| Completion | Type-aware suggestions for struct fields, effect ops, constructors |
| Go to Definition | Jump to type/function definitions (same-file and cross-file) |
| Inlay Hints | Inferred types for unannotated variables and effects |
| Semantic Tokens | Syntax highlighting for Typist keywords and type names |

**Tip:** Set `TYPIST_CHECK_QUIET=1` in your shell when using the LSP server. This suppresses redundant CHECK-phase STDERR output since the LSP provides the same diagnostics inline.

---

## Common Patterns

### BEGIN Blocks for Type Definitions

Type definitions (`typedef`, `struct`, `newtype`, `datatype`, `effect`, `typeclass`, `instance`) must be in `BEGIN` blocks so they're available during CHECK-phase analysis:

```perl
BEGIN {
    typedef Config => Record(host => Str, port => Int);
    struct  Point  => (x => Int, y => Int);
    newtype UserId => 'Int';
}
```

### typedef — Structural Aliases

```perl
BEGIN { typedef Name => Str }

my $n :sig(Name) = "Alice";    # Name is interchangeable with Str
```

### Struct — Nominal Immutable Objects

```perl
BEGIN {
    struct Person => (
        name  => Str,
        age   => Int,
        optional(email => Str),
    );
}

my $p = Person(name => "Alice", age => 30);
say $p->name;                              # getter
my $q = Person::derive($p, age => 31, email => "a@b.c");  # immutable derive
```

### optional Fields

Use `optional(field => Type)` in struct definitions and `key? => Type` in record types:

```perl
struct Item => (name => Str, optional(desc => Str));
my $r :sig({ name => Str, desc? => Str }) = { name => "x" };   # desc omitted
```

### declare — Annotating External Functions

```perl
declare say   => '(Str) -> Void ![Console]';
declare chomp => '(Str) -> Str';
```

This registers type information for functions Typist can't see the source of.

### Gradual Adoption

You don't have to annotate everything at once. Typist enforces checks proportional to annotation density:

- **Fully annotated** — all checks active
- **Partially annotated** — checked where annotations exist
- **Unannotated** — treated as `(Any...) -> Any`, effectively skipped

Start by annotating module boundaries (public functions), then work inward.

---

## Common Pitfalls

### 1. Missing BEGIN for type definitions

```perl
# WRONG — typedef not visible during CHECK
typedef Name => Str;

# RIGHT
BEGIN { typedef Name => Str }
```

### 2. Hash reference ambiguity

Perl can confuse `{}` (hashref) with `{}` (block). Use `+{}` to disambiguate:

```perl
effect Console => +{           # +{} = hashref
    writeLine => '(Str) -> Void',
};
```

### 3. Array vs ArrayRef

`Array[T]` and `ArrayRef[T]` are different types:

- `Array[T]` — a list-producing expression (Perl list context)
- `ArrayRef[T]` — a scalar reference to an array

They are **not** subtypes of each other. For variables and data structures, you almost always want `ArrayRef[T]`.

### 4. 0/1 and Bool

By default, `0` and `1` are `Int`, not `Bool`:

```perl
my $x :sig(Int) = 0;    # ok: Literal(0, Int)
my $b :sig(Bool) = 0;   # ok: bidirectional inference makes it Bool
```

Only with a `Bool` annotation context do `0`/`1` become `Bool`.

### 5. `die` as a list operator

Perl's `die` has surprising precedence:

```perl
# WRONG — die sees the hash pair as its argument list
$x // die "msg", key => "val";

# RIGHT
$x // die("msg\n");
```

### 6. No comma after block in `handle`/`map`/`grep`

```perl
# WRONG — comma after block breaks the prototype
handle { $body }, Effect => +{ ... };

# RIGHT — no comma after the block
handle { $body } Effect => +{ ... };
```

This is a Perl prototype rule: `(&@)` prototypes (used by `handle`, `map`, `grep`) expect the block without a trailing comma.

---

## Next Steps

| Document | What you'll learn |
|----------|-------------------|
| [Type System Reference](type-system.md) | All type constructs, subtyping rules, DSL, effect system |
| [Architecture](architecture.md) | Internal design, module graph, validation layers |
| [Static Analysis](static-analysis.md) | How the analyzer works, inference rules, gradual typing semantics |
| [LSP Coverage](lsp-coverage.md) | Full feature matrix and diagnostic kinds |
| [Conventions](conventions.md) | Coding conventions, Perl gotchas |
| `example/` directory | 12 runnable examples covering every feature |

Run the examples to see each feature in action:

```sh
perl example/01_foundations.pl       # Type aliases, variables, functions
perl example/02_composite_types.pl   # Struct, Union, Maybe
perl example/03_generics.pl          # Generics, bounded quantification
perl example/07_effects.pl           # Effect system and handlers
perl example/11_static_errors.pl     # Intentional errors for demo
```
