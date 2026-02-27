# CLAUDE.md

## Project Overview

Typist is a pure Perl type system for Perl 5.40+. It provides type annotations via attributes and enforces them through `tie` (scalars) and sub wrapping (functions).

## Architecture

```
Typist.pm                  — Entry point. Registers packages, installs attributes, exports typedef.
Typist::Parser             — Recursive-descent parser for type expressions.
Typist::Registry           — Global singleton. Stores aliases, function signatures, variables, packages.
Typist::Type               — Abstract base class for all type nodes.
  ::Type::Atom             — Primitives (Any, Num, Int, Bool, Str, Undef, Void). Flyweight pool.
  ::Type::Param            — ArrayRef[T], HashRef[K,V], Tuple[...], Ref[T].
  ::Type::Union            — T | U. Normalizing constructor.
  ::Type::Intersection     — T & U. Normalizing constructor.
  ::Type::Func             — CodeRef[A, B -> R].
  ::Type::Struct           — { key => Type, ... }.
  ::Type::Var              — Single uppercase letter type variables.
  ::Type::Alias            — Named aliases, lazily resolved via Registry.
Typist::Subtype            — Structural subtype relation (is_subtype).
Typist::Inference          — Runtime value inference + HM-style unification for generics.
Typist::Attribute          — Perl attribute handlers for :Type, :Params, :Returns, :Generic.
Typist::Checker            — CHECK-phase static analysis (alias cycles, undeclared vars).
Typist::Error              — Structured error collection and reporting.
Typist::Tie::Scalar        — Tie-based scalar guard. Validates on every STORE.
```

## Conventions

- All modules use `use v5.40` and subroutine signatures (`($self, $arg, ...)`).
- Type nodes are immutable value objects. `substitute` returns new nodes.
- Atom types use a flyweight pool (`%POOL`) for singleton semantics.
- Union and Intersection constructors normalize (flatten, deduplicate).
- Sub wrapping uses direct glob assignment to replace the original.
- No source filters or external preprocessors.

## Commands

```sh
# Install dependencies
carton install

# Run all tests
carton exec -- prove -l t/ t/static/ t/lsp/ t/critic/

# Run a specific test
carton exec -- prove -l t/00_compile.t
```

## Test Structure

Tests are numbered and ordered by dependency:
- `t/00_compile.t` — Module loading
- `t/01_parser.t` — Type expression parsing
- `t/02_subtype.t` — Subtype relation
- `t/03_attribute.t` — Attribute-based type annotations
- `t/04_inference.t` — Type inference and unification
- `t/05_integration.t` — End-to-end scenarios
