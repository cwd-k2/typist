# CLAUDE.md

## Project Overview

Typist is a pure Perl type system for Perl 5.40+. It provides type annotations via attributes and enforces them through `tie` (scalars) and sub wrapping (functions). The type system supports generics, type classes, higher-kinded types, nominal types, recursive types, literal types, and bounded quantification.

## Architecture

```
Typist.pm                  — Entry point. Registers packages, installs attributes, exports typedef/newtype/unwrap/typeclass/instance.
Typist::Parser             — Recursive-descent parser for type expressions (atoms, params, unions, intersections, structs, literals).
Typist::Registry           — Global singleton. Stores aliases, newtypes, typeclasses, instances, function signatures, variables, packages.
Typist::Type               — Abstract base class for all type nodes.
  ::Type::Atom             — Primitives (Any, Num, Int, Bool, Str, Undef, Void, Never). Flyweight pool.
  ::Type::Param            — ArrayRef[T], HashRef[K,V], Tuple[...], Ref[T].
  ::Type::Union            — T | U. Normalizing constructor.
  ::Type::Intersection     — T & U. Normalizing constructor.
  ::Type::Func             — CodeRef[A, B -> R].
  ::Type::Struct           — { key => Type, key? => Type, ... }. Required + optional field support.
  ::Type::Var              — Type variables (single or multi-char). Optional bound and kind.
  ::Type::Alias            — Named aliases, lazily resolved via Registry. Supports recursive types.
  ::Type::Literal          — Singleton literal types: "hello", 42, 3.14.
  ::Type::Newtype          — Nominal wrapper types. Blessed scalar ref, no structural subtyping.
Typist::Transform          — Post-parse tree walk: converts Alias → Var for :Generic-declared names.
Typist::Subtype            — Structural subtype relation (is_subtype). Handles Never, Literal, Newtype, Optional struct fields.
Typist::Inference          — Runtime value inference + HM-style unification for generics.
Typist::Attribute          — Perl attribute handlers for :Type, :Params, :Returns, :Generic. Bounded + typeclass constraint checking.
Typist::Checker            — CHECK-phase static analysis (alias cycles, undeclared vars, bound well-formedness).
Typist::Error              — Structured error collection and reporting.
Typist::Tie::Scalar        — Tie-based scalar guard. Validates on every STORE.
Typist::TypeClass          — Type class definition (Def) and instance (Inst) structures.
Typist::Kind               — Kind system: Star (*) and Arrow (* -> *).
Typist::KindChecker        — Kind inference and application checking for type constructors.
```

## Conventions

- All modules use `use v5.40` and subroutine signatures (`($self, $arg, ...)`).
- Type nodes are immutable value objects. `substitute` returns new nodes.
- Atom types use a flyweight pool (`%POOL`) for singleton semantics.
- Union and Intersection constructors normalize (flatten, deduplicate).
- Sub wrapping uses direct glob assignment to replace the original.
- Hashref literals always use `+{}` to disambiguate from blocks.
- No source filters or external preprocessors.

## Commands

```sh
mise run deps              # Install dependencies
mise run test              # Run all tests (parallel)
mise run test:core         # Core type system tests
mise run test:static       # Static analysis tests
mise run test:lsp          # LSP server tests
mise run test:critic       # Perl::Critic policy tests
mise run example           # Run all examples
mise run example:basics    # Run basics example
mise run example:generics  # Run generics example
```

## Test Structure

Tests are numbered and ordered by dependency:
- `t/00_compile.t` — Module loading
- `t/01_parser.t` — Type expression parsing (including literals, optional struct fields)
- `t/02_subtype.t` — Subtype relation (including Never, optional struct, literal subtyping)
- `t/03_attribute.t` — Attribute-based type annotations
- `t/04_inference.t` — Type inference and unification
- `t/05_integration.t` — End-to-end scenarios
- `t/06_instance.t` — Instance-based Registry/Checker
- `t/07_multivar.t` — Multi-character type variables and Transform
- `t/08_literal.t` — Literal types (string, numeric)
- `t/09_newtype.t` — Nominal types (newtype, contains, subtype)
- `t/10_recursive.t` — Recursive type definitions (JsonValue, IntList)
- `t/11_bounded.t` — Bounded quantification (:Generic(T: Num))
- `t/12_typeclass.t` — Type classes (definition, instances, dispatch)
- `t/13_hkt.t` — Higher-kinded types and Kind system
