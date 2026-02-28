# CLAUDE.md

## Project Overview

Typist is a pure Perl type system for Perl 5.40+. It provides type annotations via attributes and uses a **static-first** architecture: errors are caught at compile time (CHECK phase) and via LSP, with runtime enforcement available as an opt-in mode. The type system supports generics, type classes, higher-kinded types, nominal types, recursive types, literal types, bounded quantification, and algebraic effects with row polymorphism.

## Architecture

```
Static-First (default)       Runtime (opt-in: -runtime)    LSP Layer
──────────────────────       ─────────────────────────     ──────────────
Typist.pm (entry+CHECK)      Tie::Scalar                   LSP::Server
Static::Checker              Attribute._wrap_sub            LSP::Document
Static::Analyzer (CHECK)     Inference.pm                   LSP::Workspace
Static::TypeChecker          Handler (perform/handle)       LSP::Hover
Static::EffectChecker                                       LSP::Completion
Static::Extractor                                           LSP::Transport
Static::Infer
Static::Unify

Shared Infrastructure
──────────────────────────
Registry, Parser, Subtype, Transform, Attribute, Prelude
Error (value + Collector), Error::Global (singleton buffer)
Type::{Atom,Param,Union,Intersection,Func,Struct,Var,Alias,Literal,Newtype,Row,Eff,Data}
Type::Fold (map_type, walk)
Kind, KindChecker, TypeClass, Effect
DSL (Type constructors: Int, Str, ArrayRef(...), Struct(...), Func(...), etc.)
```

### Error Detection Phases

```
Phase           | Catches                    | Surface       | Tool Integration
────────────────|────────────────────────────|───────────────|─────────────────
Static (LSP)    | TypeMismatch, EffectMis.   | Diagnostics   | typist-lsp, editors
                | ArityMismatch, CycleError  |               |
                | UnknownType                |               |
CHECK (compile) | All of above (expanded)    | warn → STDERR | perlnavigator, prove
Runtime (opt-in)| Generic instantiation      | die           | -runtime flag
                | TypeClass constraints      |               |
                | perform/handle (effects)   |               |
                | Boundary (newtype) [always] |              |
```

### Key Modules

- `Typist::DSL` — Type DSL with operator overloading. Exports atom constants (`Int`, `Str`, `Num`, ...), type variable constants (`T`, `U`, `V`, ...), and parametric constructors (`ArrayRef(...)`, `Struct(...)`, `Func(..., returns => R)`). Enables `typedef Name => Str | Int` syntax.
- `Typist::Type` — Abstract base with `|` (union), `&` (intersection), `""` (stringify) overloads. `coerce($expr)` accepts both Type objects and strings.
- `Typist::Error` — Value class + Collector (instance-based). `Typist::Error::Global` provides the global singleton buffer.
- `Typist::Static::Checker` — CHECK-phase validation (alias cycles, undeclared vars, bound/kind/effect well-formedness).
- `Typist::Prelude` — Builtin function type annotations for Perl core functions (say, print, die, length, substr, abs, sqrt, open, close, etc. — 19 functions). Installed into CORE:: namespace via `install($registry)`. Auto-loaded by Analyzer and Workspace. User `declare` overrides entries.
- `Typist::Static::Unify` — Type-based unification. Pairs formal (annotated) types against actual (inferred) types, extracting type-variable bindings. Used by TypeChecker for generic function instantiation.
- `Typist::Static::Infer` — Static type inference from PPI elements (literals, variable symbols, function calls, operator expressions). Infers arithmetic/comparison/logical/concatenation operators, subscript access (`$a->[0]`, `$h->{k}`), and ternary expressions. Accepts optional `$env` for gradual typing.
- `Typist::Static::TypeChecker` — Static type mismatch detection (variable initializers, assignments, call site args, return types). Arity checking (ArityMismatch), variable reassignment checking (annotated-only), method type checking (`$self->method()`), generic instantiation via Unify, and type narrowing (`defined($x)` guard narrows `Maybe[T]` to `T`). Builds type environment for function return type propagation and variable symbol resolution.
- `Typist::Static::EffectChecker` — PPI-based static effect checker (call graph + label inclusion, cross-package support, unannotated function detection, builtin function effect tracking via CORE:: registry).
- `Typist::Handler` — Runtime effect handler stack (LIFO). `perform` dispatches to the nearest handler; `handle { BODY } Effect => { handlers }` provides scoped effect processing with automatic cleanup.
- `Typist::Type::Data` — Algebraic data type (tagged union). Values are blessed with `_tag` and `_values` fields. Supports `contains`, `substitute`, and `free_vars`. Defined via `datatype Name => Tag => '(Types)', ...`.
- `Typist::Type::Fold` — Type tree traversal utilities. `map_type($type, $cb)` rebuilds bottom-up; `walk($type, $cb)` visits top-down. Handles all type nodes including Data.
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
- Static-first: `use Typist;` = static-only (default). Runtime enforcement via `use Typist -runtime;` or `TYPIST_RUNTIME=1`. Newtype constructors and `unwrap` always validate (boundary enforcement).
- CHECK phase runs both structural checks (Checker) and full static analysis (Analyzer with TypeChecker + EffectChecker) per loaded package. Diagnostics surface as `warn` → perlnavigator picks these up. Suppress with `TYPIST_CHECK_QUIET=1` when using typist-lsp.
- Gradual typing: fully annotated → all checks enforced; partially annotated (some attrs, no `:Eff`) → pure, return type unknown if no `:Returns`; completely unannotated → `(Any...) -> Any ! Eff(*)`, type checks skip, effect checks flag.
- `datatype Shape => Circle => '(Int)', Rectangle => '(Int, Int)'` defines ADTs (tagged unions). Constructors are installed into the caller's namespace.
- `perform Effect => op => @args` dispatches an effect operation to the nearest handler on the runtime stack.
- `handle { BODY } Effect => { op => sub { ... } }` installs scoped effect handlers, executes BODY, and guarantees cleanup (even on exception).
- Prelude: builtin functions are registered under the CORE:: namespace by `Typist::Prelude->install`. User `declare` statements override prelude entries.
- Type Narrowing: `defined($x)` in an if-condition narrows `Maybe[T]` (i.e., `T | Undef`) to `T` within the then-block.
- Variable reassignment: `:Type` annotated variables are checked on reassignment (`$x = expr`); unannotated variables are not checked.
- Method calls: `$self->method()` is type-checked within the same package via registry lookup; cross-package method calls are gradual-skipped.

## Commands

```sh
mise run deps              # Install dependencies
mise run test              # Run all tests (parallel)
mise run test:core         # Core type system tests
mise run test:static       # Static analysis tests
mise run test:lsp          # LSP server tests
mise run test:critic       # Perl::Critic policy tests
mise run test:e2e          # LSP E2E smoke test (subprocess)
mise run test:workspace    # Verify LSP workspace on realworld example
mise run example           # Run all examples
mise run example:basics    # Run basics example
mise run example:generics  # Run generics example
mise run example:gradual   # Run gradual typing example
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
- `t/19_fold.t` — Type::Fold (map_type, walk)
- `t/20_check_diagnostics.t` — CHECK-phase static analysis (subprocess-based, TypeMismatch/EffectMismatch detection, -runtime flag, TYPIST_RUNTIME env)
- `t/21_datatype.t` — Algebraic data types (constructors, contains, subtype)
- `t/22_effects_handler.t` — Effect handlers (perform, handle, handler stack)
- `t/static/00_extractor.t` — PPI-based type extraction
- `t/static/01_analyzer.t` — Static analysis pipeline
- `t/static/02_infer.t` — Static type inference
- `t/static/03_typecheck.t` — Static type mismatch detection
- `t/static/04_effects.t` — Static effect mismatch detection
- `t/static/05_extractor_advanced.t` — Extractor: newtype/effect/typeclass extraction
- `t/static/06_crossfile_analyzer.t` — Cross-file type resolution via workspace registry
- `t/static/07_method_typecheck.t` — Method type checking (is_method, -> guard, $self->method())
- `t/static/08_prelude.t` — Builtin prelude (type checking, effect detection, user override)
- `t/lsp/00_transport.t` — JSON-RPC transport
- `t/lsp/01_server.t` — LSP server lifecycle
- `t/lsp/02_diagnostics.t` — Diagnostics publishing
- `t/lsp/03_hover.t` — Hover provider
- `t/lsp/04_completion.t` — Completion provider
- `t/lsp/05_workspace.t` — Workspace scanning
- `t/lsp/06_workspace_crossfile.t` — Cross-file workspace registration
- `t/lsp/07_crossfile_diagnostics.t` — Cross-file re-diagnosis on save
- `t/lsp/08_workspace_realworld.t` — Workspace integration on realworld example (diagnostics, hover, completion)
- `t/lsp/09_document_symbol.t` — DocumentSymbol provider
- `t/lsp/10_definition.t` — Go to Definition
- `t/lsp/11_signature_help.t` — Signature Help
- `t/lsp/12_inlay_hints.t` — Inlay Hints
- `t/critic/00_policy.t` — Perl::Critic policy bridge
