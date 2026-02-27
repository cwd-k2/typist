# Typist

A type system for Perl, implemented in pure Perl.

Typist brings static-style type annotations to Perl 5.40+ through standard attribute syntax and `tie` mechanics — no source filters, no external tooling.

## Synopsis

```perl
use Typist;

# Type aliases
typedef Name   => 'Str';
typedef Config => '{ host => Str, port => Int }';

# Typed variables
my $count :Type(Int) = 0;
my $label :Type(Maybe[Str]) = undef;

# Typed subroutines
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
    $a + $b;
}

# Generics
sub first :Generic(T) :Params(ArrayRef[T]) :Returns(T) ($arr) {
    $arr->[0];
}

# Algebraic effects
effect Console => +{
    readLine  => 'CodeRef[-> Str]',
    writeLine => 'CodeRef[Str -> Void]',
};

sub greet :Params(Str) :Returns(Str) :Eff(Console) ($name) {
    "Hello, $name!";
}

# Row polymorphism — "at least Log, plus whatever r adds"
sub with_log :Generic(r: Row) :Params(Str) :Returns(Str) :Eff(Log | r) ($msg) {
    $msg;
}
```

## Features

- **Primitive types** — `Any`, `Num`, `Int`, `Bool`, `Str`, `Undef`, `Void`
- **Parameterized types** — `ArrayRef[T]`, `HashRef[K, V]`, `Tuple[T, U, ...]`, `Ref[T]`
- **Union & Intersection** — `Int | Str`, `Readable & Writable`
- **Function types** — `CodeRef[Int, Int -> Int]`
- **Struct types** — `{ name => Str, age => Int }`
- **Maybe sugar** — `Maybe[T]` desugars to `T | Undef`
- **Named aliases** — `typedef` for reusable type definitions
- **Literal types** — `42`, `"hello"` as singleton types
- **Newtype** — `newtype UserId => 'Int'` for nominal (non-structural) type identity
- **Recursive types** — self-referential `typedef` through type constructors
- **Generics** — `:Generic(T)` with Hindley-Milner style unification
- **Bounded quantification** — `:Generic(T: Num)` to constrain type variables
- **Type classes** — `typeclass` / `instance` with ad-hoc polymorphism dispatch
- **Higher-kinded types** — `F: * -> *` kind annotations for type constructor abstraction
- **Algebraic effects** — `effect` keyword, `:Eff(Console | Log)` annotations, row polymorphism via `:Generic(r: Row)`
- **Structural subtyping** — width subtyping for structs, contravariant parameters for functions
- **CHECK-phase analysis** — detects alias cycles, unknown types, and undeclared type variables before runtime
- **LSP server** — hover, completion, and diagnostics for editors
- **Perl::Critic policy** — type error detection via PerlNavigator

## Requirements

- Perl 5.40+
- [Carton](https://metacpan.org/pod/Carton)

## Setup

```sh
carton install
```

This installs runtime dependencies (`PPI`, `JSON::PP`) into `local/`. For optional Perl::Critic integration:

```sh
carton install --with-recommends
```

## Editor Integration

Typist provides two layers of editor integration:

### Perl::Critic Policy (via PerlNavigator)

If you already use PerlNavigator, add the Typist policy to get inline type error diagnostics:

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

### LSP Server

The standalone LSP server provides hover, completion, and diagnostics:

```sh
carton exec -- perl bin/typist-lsp
```

**Capabilities:**

- **Diagnostics** — alias cycles, unknown types, undeclared type variables
- **Hover** — type signatures for variables, functions, and typedefs
- **Completion** — type names inside `:Type()`, `:Params()`, `:Returns()`, `:Generic()`, `:Eff()`

#### Neovim (nvim-lspconfig)

```lua
local configs = require('lspconfig.configs')

configs.typist = {
  default_config = {
    cmd = { 'carton', 'exec', '--', 'perl', 'bin/typist-lsp' },
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

Carton automatically adds `lib/` and `local/lib/perl5` to `@INC`.

#### VS Code

Use the `vscode-languageclient` extension with this server configuration:

```json
{
  "typist-lsp.command": "carton",
  "typist-lsp.args": ["exec", "--", "perl", "bin/typist-lsp"]
}
```

## Examples

See `example/` for runnable demonstrations:

- `example/basics.pl` — typed variables, typed functions, typedef, error handling
- `example/generics.pl` — generic functions, parameterized types, union types
- `example/effects.pl` — algebraic effects, row polymorphism, phantom effect tracking
- `example/haskell.pl` — newtype, literal types, recursive types, bounded quantification, type classes, HKT
- `example/lsp_demo.pm` — module showcasing LSP hover/completion/diagnostic targets

```sh
carton exec -- perl example/basics.pl
carton exec -- perl example/generics.pl
carton exec -- perl example/effects.pl
carton exec -- perl example/haskell.pl
```

## Testing

```sh
# All tests
carton exec -- prove -l t/ t/static/ t/lsp/ t/critic/

# Core type system
carton exec -- prove -l t/

# Static analysis engine
carton exec -- prove -l t/static/

# LSP server
carton exec -- prove -l t/lsp/

# Perl::Critic policy (requires Perl::Critic)
carton exec -- prove -l t/critic/
```

## License

This is free software; you can redistribute it and/or modify it under the same terms as the Perl 5 programming language system itself.
