# CLAUDE.md

## Project Overview

Typist is a pure Perl type system for Perl 5.40+. It provides type annotations via attributes and enforces them through `tie` (scalars) and sub wrapping (functions). The type system supports generics, type classes, higher-kinded types, nominal types, recursive types, literal types, bounded quantification, and algebraic effects with row polymorphism.

## Architecture

```
Runtime Layer                Static Analysis Layer         LSP Layer
──────────────────           ─────────────────────         ──────────────
Typist.pm (entry)            Static::Extractor             LSP::Server
Attribute.pm                 Static::Analyzer              LSP::Document
Tie::Scalar                  Static::Checker (CHECK)       LSP::Workspace
Inference.pm                 Static::TypeChecker           LSP::Hover
                             Static::EffectChecker         LSP::Completion
                             Static::Infer                 LSP::Transport

Shared Infrastructure
──────────────────────────
Registry, Parser, Subtype, Transform
Error (value + Collector), Error::Global (singleton buffer)
Type::{Atom,Param,Union,Intersection,Func,Struct,Var,Alias,Literal,Newtype,Row,Eff}
Kind, KindChecker, TypeClass, Effect
DSL (Type constructors: Int, Str, ArrayRef(...), Struct(...), Func(...), etc.)
```

### Key Modules

- `Typist::DSL` — Type DSL with operator overloading. Exports atom constants (`Int`, `Str`, `Num`, ...), type variable constants (`T`, `U`, `V`, ...), and parametric constructors (`ArrayRef(...)`, `Struct(...)`, `Func(..., returns => R)`). Enables `typedef Name => Str | Int` syntax.
- `Typist::Type` — Abstract base with `|` (union), `&` (intersection), `""` (stringify) overloads. `coerce($expr)` accepts both Type objects and strings.
- `Typist::Error` — Value class + Collector (instance-based). `Typist::Error::Global` provides the global singleton buffer.
- `Typist::Static::Checker` — CHECK-phase validation (alias cycles, undeclared vars, bound/kind/effect well-formedness).
- `Typist::Static::EffectChecker` — PPI-based static effect checker (call graph + label inclusion, cross-package support).
- `Typist::Subtype` — Structural subtype relation + `common_super` (LUB for atom types).
- `Typist::Attribute` — Attribute handlers + `parse_generic_decl` (shared between runtime and static paths).
- `Typist::TypeClass` — Type class Def (with `install_dispatch`, `check_instance_completeness`, `resolve`) and Inst structures.

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
mise run test:e2e          # LSP E2E smoke test (subprocess)
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
- `t/14_effects_foundation.t` — Effect/Row/Eff types, Kind::Row
- `t/15_effects_row.t` — Row parsing, subtyping, unification
- `t/16_effects_attribute.t` — :Eff attribute, effect keyword, :Generic(r: Row)
- `t/17_effects_integration.t` — End-to-end effect system scenarios
- `t/18_dsl.t` — Type DSL (operators, constructors, coerce)
- `t/static/00_extractor.t` — PPI-based type extraction
- `t/static/01_analyzer.t` — Static analysis pipeline
- `t/static/02_infer.t` — Static type inference
- `t/static/03_typecheck.t` — Static type mismatch detection
- `t/static/04_effects.t` — Static effect mismatch detection
- `t/static/05_extractor_advanced.t` — Extractor: newtype/effect/typeclass extraction
- `t/static/06_crossfile_analyzer.t` — Cross-file type resolution via workspace registry
- `t/lsp/00_transport.t` — JSON-RPC transport
- `t/lsp/01_server.t` — LSP server lifecycle
- `t/lsp/02_diagnostics.t` — Diagnostics publishing
- `t/lsp/03_hover.t` — Hover provider
- `t/lsp/04_completion.t` — Completion provider
- `t/lsp/05_workspace.t` — Workspace scanning
- `t/lsp/06_workspace_crossfile.t` — Cross-file workspace registration
- `t/lsp/07_crossfile_diagnostics.t` — Cross-file re-diagnosis on save
- `t/critic/00_policy.t` — Perl::Critic policy bridge
