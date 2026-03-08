# First Program

This page walks through writing, running, and understanding your first Typist-annotated Perl program. By the end you will know how `:sig()` annotations work, what the CHECK phase does, and how to read diagnostic output.

## Hello, Typist

Create a file called `hello_typist.pl`:

```typist
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

Output:

```
Hello, world!
```

No warnings, no errors -- the types check out.

### What just happened

Three things occurred in sequence:

1. **Compile time.** Perl compiled the file. The `use Typist` statement installed the `:sig()` attribute handler and registered the annotation parser.
2. **CHECK phase.** Before the program body executed, Typist's static analyzer ran. It verified that `greet` receives a `Str` and returns a `Str`, that the call site `greet("world")` passes a `Str`, and that `$msg` is assigned a value compatible with its declared type `Str`.
3. **Runtime.** The program body executed normally. With plain `use Typist`, no runtime type checks are performed, and no static CHECK pass runs unless you opt in with `-check` or `TYPIST_CHECK=1`.

## Key Concepts

### The `:sig()` annotation

Every type annotation in Typist uses the `:sig()` attribute syntax. It works on both variables and subroutines:

```typist
# Variable: :sig(Type)
my $count :sig(Int) = 0;

# Function: :sig((ParamTypes) -> ReturnType)
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
```

For subroutines, the parameter types go inside inner parentheses, followed by `->` and the return type. This mirrors standard type theory notation for function types.

### Type expressions are strings

All type declarations in Typist use strings, not barewords:

```typist
typedef Name => 'Str';           # string, not bareword
struct Point => (x => 'Int', y => 'Int');
```

Inside `:sig()`, type names are written directly without quotes -- the annotation parser handles them:

```typist
sub f :sig((Int) -> Str) ($n) { "$n" }
```

### The CHECK phase

Perl's CHECK phase runs after compilation but before execution. Typist hooks into this phase to run its static analyzer. Diagnostics are emitted as warnings on STDERR. In the default mode, the program continues to execute even if type errors are found -- the warnings tell you what to fix, but they do not abort your program.

## A More Complete Example

Create `typed_geometry.pl`:

```typist
use v5.40;
use lib 'lib';
use Typist;

BEGIN {
    typedef Name => 'Str';
    struct Point => (x => 'Int', y => 'Int');
}

sub distance :sig((Point, Point) -> Double) ($a, $b) {
    sqrt(($a->x - $b->x) ** 2 + ($a->y - $b->y) ** 2);
}

my $p1 = Point(x => 0, y => 0);
my $p2 = Point(x => 3, y => 4);
say distance($p1, $p2);   # 5
```

Run it:

```sh
perl typed_geometry.pl
```

Output:

```
5
```

### Why BEGIN blocks?

The `typedef` and `struct` declarations are wrapped in a `BEGIN` block. This is necessary because type definitions must be available during the CHECK phase, when the static analyzer resolves type names in `:sig()` annotations. Without `BEGIN`, the definitions would not exist yet when the analyzer runs.

The rule is straightforward: any declaration that defines a type name -- `typedef`, `struct`, `newtype`, `datatype`, `enum`, `effect`, `typeclass`, `instance` -- belongs in a `BEGIN` block.

### Struct basics

`struct` creates a nominal, immutable type with named fields. Calling the constructor `Point(x => 0, y => 0)` returns a blessed, frozen object. Field access uses generated accessor methods:

```typist
my $p = Point(x => 3, y => 4);
$p->x;    # 3
$p->y;    # 4
```

Structs are immutable. To create a modified copy, use `derive`:

```typist
my $moved = Point::derive($p, x => 10);   # Point(x => 10, y => 4)
```

## Catching Type Errors

Introduce an intentional error to see what diagnostics look like. Create `type_error.pl`:

```typist
use v5.40;
use lib 'lib';
use Typist;

sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }

my $result = add("five", 3);
say $result;
```

Run it:

```sh
perl type_error.pl
```

STDERR output:

```
Type error in main: expected Int, got Str in argument 1 of add at line 7.
```

The program still runs (printing a result from Perl's string-to-number coercion), but `typist-check`, the LSP, or opt-in CHECK analysis (`use Typist -check;`) tells you exactly where the type contract was violated: argument 1 of `add` at line 7 expected `Int` but received `Str`.

### Using typist-check

For a cleaner diagnostic experience, use the `typist-check` CLI tool instead of running the file directly:

```sh
perl -Ilib bin/typist-check type_error.pl
```

Output:

```
type_error.pl
  7:5    error    expected Int, got Str in argument 1  [TypeMismatch]

1 error(s) in 1 file(s) (1 file checked)
```

The CLI tool provides structured output with file paths, line:column positions, severity levels, and diagnostic kind tags. It also uses color by default (suppressed here for readability). Exit code `1` signals that errors were found.

## What Comes Next

You now know the three essential pieces: `:sig()` annotations for declaring types, `BEGIN` blocks for type definitions, and the CHECK phase for catching errors before your program runs.

From here:

- **[Editor Setup](editor-setup.md)** -- Configure your editor for real-time diagnostics, hover, and completion.
- **[Guide](../guide/index.md)** -- The `:sig()` syntax, compound types, static vs runtime mode, and more.
- **`example/` directory** -- Twelve runnable examples covering every feature, from foundations through effects and protocols.
