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
Static::TypeChecker          Handler (Effect::op/handle)    LSP::Hover
Static::EffectChecker                                       LSP::Completion
Static::Extractor                                           LSP::Transport
Static::Infer                                               LSP::CodeAction
Static::Unify                                               LSP::SemanticTokens
                                                            LSP::Logger

Shared Infrastructure
──────────────────────────
Registry, Parser, Subtype, Transform, Attribute, Prelude
Error (value + Collector), Error::Global (singleton buffer)
Type::{Atom,Param,Union,Intersection,Func,Record,Struct,Var,Alias,Literal,Newtype,Row,Eff,Data}
Type::Fold (map_type, walk)
Struct::Base (blessed immutable object base)
Kind, KindChecker, TypeClass, Effect
Static::Registration (shared type registration)
DSL (Type constructors: Int, Str, ArrayRef(...), Record(...), Func(...), optional(), etc.)
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
                | Effect::op/handle (effects)|               |
                | Boundary (newtype) [always] |              |
```

### Key Modules

- `Typist::DSL` — Type DSL with operator overloading. Exports atom constants (`Int`, `Str`, `Num`, ...), type variable constants (`T`, `U`, `V`, ...), parametric constructors (`ArrayRef(...)`, `Record(...)`, `Func(..., returns => R)`), and `optional()` for struct/record field declarations. Enables `typedef Name => Str | Int` syntax.
- `Typist::Type` — Abstract base with `|` (union), `&` (intersection), `""` (stringify) overloads. `coerce($expr)` accepts both Type objects and strings.
- `Typist::Error` — Value class + Collector (instance-based). `Typist::Error::Global` provides the global singleton buffer.
- `Typist::Static::Checker` — CHECK-phase validation (alias cycles, undeclared vars, bound/kind/effect well-formedness).
- `Typist::Prelude` — Builtin function type annotations for Perl core functions and Typist builtins (say, print, die, length, typedef, unwrap, etc. — 83 functions). Installed into CORE:: namespace via `install($registry)`. Auto-loaded by Analyzer and Workspace. User `declare` overrides entries. `builtin_names()` class method returns the canonical name list (single source of truth for Document/EffectChecker).
- `Typist::Static::Unify` — Type-based unification. Pairs formal (annotated) types against actual (inferred) types, extracting type-variable bindings. `collect_bindings($formal, $actual, $bindings)` is the shared binding-collection method used by both Infer.pm and Subtype.pm. Used by TypeChecker for generic function instantiation.
- `Typist::Static::Infer` — Static type inference from PPI elements (literals, variable symbols, function calls, operator expressions, anonymous subs). Infers arithmetic/comparison/logical/concatenation/repetition operators, chained binary expressions, compound assignment operators, subscript access (`$a->[0]`, `$h->{k}`), method access (`$p->name` for struct accessors), ternary expressions, `handle { BLOCK }` return types, `match` arm union/LUB types, and anonymous sub types (`sub ($x) { ... }` → Func type with param count and body return inference). Interpolated strings (`"Hello $name"`) infer as `Str`, not `Literal`. Bidirectional: accepts optional `$expected` for propagation into arrays, hashes, ternary arms, and anonymous sub param types. Accepts optional `$env` for gradual typing.
- `Typist::Static::TypeChecker` — Static type mismatch detection (variable initializers, assignments, call site args, return types). Arity checking (ArityMismatch) with default parameter support and callback arity checking (anonymous sub param count vs expected Func type), variable reassignment checking (annotated-only), method type checking (`$self->method()`), generic instantiation via Unify, and control flow narrowing (`defined($x)`, truthiness `if ($x)`, `isa`, early return). Builds type environment for function return type propagation and variable symbol resolution.
- `Typist::Static::EffectChecker` — PPI-based static effect checker (call graph + label inclusion, cross-package support, unannotated function detection, builtin function effect tracking via CORE:: registry). Keywords `handle`, `match`, `enum` are skipped as non-function calls.
- `Typist::Handler` — Runtime effect handler stack (LIFO). Effect operations are dispatched as qualified calls (`Effect::op(@args)`) to the nearest handler; `handle { BODY } Effect => { handlers }` provides scoped effect processing with automatic cleanup.
- `Typist::Type::Data` — Algebraic data type (tagged union). Supports parameterized types via `datatype 'Option[T]' => Some => '(T)', None => '()'` with covariant type arguments, type inference in constructors, and `instantiate` for concrete types. Values are blessed with `_tag`, `_values`, and optional `_type_args` fields. GADT support via `return_types` field: `is_gadt`, `constructor_return_type($tag)`, `parse_constructor_spec($spec, %opts)`.
- `Typist::Type::Fold` — Type tree traversal utilities. `map_type($type, $cb)` rebuilds bottom-up; `walk($type, $cb)` visits top-down. Handles all type nodes including Data (variants, type_args, return_types).
- `Typist::Subtype` — Structural subtype relation + `common_super` (LUB for atom and record types). Struct (nominal) is subtype of matching Record (structural), but not vice versa. `_instantiate_check` delegates to `Unify->collect_bindings` for rank-2 polymorphism.
- `Typist::Registry` — Type/function registration store (singleton + instance). `name_index` reverse index for O(1) `search_function_by_name`. `unregister_function($pkg, $name)` supports differential workspace updates. `merge()` and `reset()` maintain the index.
- `Typist::Parser` — Type expression parser with parse caching. `parse($expr)` and `parse_annotation($input)` results are cached (type objects are immutable). 1000-entry eviction limit.
- `Typist::Attribute` — Attribute handlers + `parse_generic_decl` (shared between runtime and static paths).
- `Typist::TypeClass` — Type class Def (with `install_dispatch`, `check_instance_completeness`, `resolve`) and Inst structures.
- `Typist::LSP::Transport` — JSON-RPC transport (Content-Length framing, partial read loop). `uri_to_path($uri)` shared URI decoder (file:// prefix + percent-decoding), used by Server and Document.
- `Typist::LSP::Document` — Per-file analysis cache and query interface. `result` and `lines` public accessors. `symbol_at` returns symbols with LSP `range` for precise hover highlighting. `_find_word_occurrences` class method for shared word-boundary search (used by `find_references` and Workspace). `signature_context` supports multi-line calls (20-line lookback).
- `Typist::LSP::Workspace` — Cross-file type registry. Differential updates via `_unregister_file_types` (removes old entries) + `_register_file_types` (adds new).
- `Typist::Static::Extractor` — PPI-based type/function/variable extraction. `parse_loop_compound($compound)` shared loop structure parser used by both `_extract_loop_variables` and TypeChecker `_inject_loop_vars`.

## Conventions

- All modules use `use v5.40` and subroutine signatures (`($self, $arg, ...)`).
- Type nodes are immutable value objects. `substitute` returns new nodes.
- Atom types use a flyweight pool (`%POOL`) for singleton semantics.
- Union and Intersection constructors normalize (flatten, deduplicate).
- Sub wrapping uses direct glob assignment to replace the original.
- Hashref literals always use `+{}` to disambiguate from blocks.
- Two-tier composite types: **Record** (structural, plain hashrefs via `typedef Name => Record(...)`) and **struct** (nominal, blessed immutable objects via `struct Name => (fields...)`). Struct values have constructors (`Name(field => val)`), accessors (`$obj->field`), and immutable updates (`$obj->with(field => val)`). `optional(Type)` marks fields that can be omitted. Struct <: Record (structural compatibility), Record </: Struct (nominal barrier).
- No source filters or external preprocessors.
- Static-first: `use Typist;` = static-only (default). Runtime enforcement via `use Typist -runtime;` or `TYPIST_RUNTIME=1`. Newtype constructors and `unwrap` always validate (boundary enforcement).
- CHECK phase runs both structural checks (Checker) and full static analysis (Analyzer with TypeChecker + EffectChecker) per loaded package. Diagnostics surface as `warn` → perlnavigator picks these up. Suppress with `TYPIST_CHECK_QUIET=1` when using typist-lsp.
- Gradual typing: fully annotated → all checks enforced; partially annotated (some attrs, no `:Eff`) → pure, return type unknown if no `:Returns`; completely unannotated → `(Any...) -> Any ! Eff(*)`, type checks skip, effect checks flag.
- `datatype Shape => Circle => '(Int)', Rectangle => '(Int, Int)'` defines ADTs (tagged unions). Constructors are installed into the caller's namespace. Parameterized ADTs via `datatype 'Option[T]' => Some => '(T)', None => '()'` — type params are promoted from aliases to Var objects, constructors infer type arguments via `Inference->infer_value`, subtyping is covariant in type arguments.
- GADT (Generalized Algebraic Data Types): `datatype 'Expr[A]' => IntLit => '(Int) -> Expr[Int]', BoolLit => '(Bool) -> Expr[Bool]'` — constructors with `->` specify per-constructor return types. `is_gadt` predicate, `constructor_return_type($tag)` accessor. `parse_constructor_spec` shared helper parses both ADT and GADT specs. GADT constructors force type_args at runtime; static analysis infers concrete return types via argument unification.
- `enum Color => qw(Red Green Blue)` defines nullary-only ADTs (pure enumerations). Sugar for `datatype` with all zero-argument variants.
- `match $value, Tag => sub (...) { ... }, _ => sub { ... }` dispatches on `_tag`, splats `_values` into handlers. `_` is the optional fallback arm. Emits exhaustiveness warnings for registered ADTs when arms are incomplete and no fallback is given.
- Variadic function types: `(Int, ...Str) -> Void` — rest parameter with `...Type` syntax. Arity checking uses minimum args for variadic functions. Default parameters (`$x = expr`) reduce minimum arity via `default_count`.
- `effect Console => +{ writeLine => '(Str) -> Void' }` defines effects with named operations. Operations are auto-installed as qualified subs (`Console::writeLine(@args)`), dispatching to the nearest handler on the runtime stack.
- `Effect::op(@args)` is the direct call syntax for effect operations (e.g., `Console::writeLine("hello")`). Replaces the old `perform Effect => op => @args` syntax.
- `handle { BODY } Effect => { op => sub { ... } }` installs scoped effect handlers, executes BODY, and guarantees cleanup (even on exception).
- Typeclass and effect definitions use string syntax for method/operation signatures: `show => '(T) -> Str'`, consistent with `:Type()` annotations. The Extractor only captures `PPI::Token::Quote`, so DSL `Func(...)` does not work for static analysis.
- Prelude: builtin functions are registered under the CORE:: namespace by `Typist::Prelude->install`. Includes Typist builtins (typedef, newtype, unwrap, etc.) in addition to Perl core functions. User `declare` statements override prelude entries.
- `handle`/`match` return type inference: `handle { BLOCK }` infers from the block's last expression; `match` collects arm return types and computes union/LUB. These bypass the `Word + List` call pattern used for normal function inference.
- Type Narrowing: `defined($x)` narrows `Maybe[T]` to `T` in the then-block; `if ($x)` (truthiness) also narrows by removing `Undef`; `$x isa Foo` narrows to `Foo`; `return unless defined($x)` narrows `$x` for the rest of the body (early return). Else-blocks receive the inverse narrowing.
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
mise run example              # Run all examples
mise run example:foundations  # Types, aliases, functions
mise run example:composite   # Struct, Union, Maybe, etc.
mise run example:generics    # Generics, bounded quantification
mise run example:nominal     # Newtype, literals, recursive types
mise run example:algebraic   # Datatype/ADT
mise run example:typeclasses # Type classes, HKT, Functor
mise run example:effects     # Effect system, perform/handle
mise run example:gradual     # Gradual typing, flow typing
mise run example:dsl         # DSL operators, constructors
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
- `t/22_effects_handler.t` — Effect handlers (Effect::op, handle, handler stack)
- `t/23_gadt.t` — GADT (Generalized Algebraic Data Types: construction, forced type_args, is_gadt, match, return_types)
- `t/25_struct.t` — Nominal struct types (constructor, accessors, with(), optional fields, type registration, subtyping)
- `t/static/00_extractor.t` — PPI-based type extraction
- `t/static/01_analyzer.t` — Static analysis pipeline
- `t/static/02_infer.t` — Static type inference (including anonymous sub inference)
- `t/static/03_typecheck.t` — Static type mismatch detection (including callback arity checking)
- `t/static/04_effects.t` — Static effect mismatch detection
- `t/static/05_extractor_advanced.t` — Extractor: newtype/effect/typeclass extraction
- `t/static/06_crossfile_analyzer.t` — Cross-file type resolution via workspace registry
- `t/static/07_method_typecheck.t` — Method type checking (is_method, -> guard, $self->method())
- `t/static/08_prelude.t` — Builtin prelude (type checking, effect detection, user override)
- `t/static/09_builtins_infer.t` — Typist builtin inference (handle/match return types, unwrap CORE registration)
- `t/static/10_rank2.t` — Rank-2 polymorphism static analysis
- `t/static/11_struct.t` — Struct static analysis (extraction, registration, inference)
- `t/static/12_loop_inference.t` — Loop variable inference (for-loop extraction, iterable element types)
- `t/lsp/00_transport.t` — JSON-RPC transport
- `t/lsp/01_server.t` — LSP server lifecycle
- `t/lsp/02_diagnostics.t` — Diagnostics publishing
- `t/lsp/03_hover.t` — Hover provider
- `t/lsp/04_completion.t` — Completion provider
- `t/lsp/05_workspace.t` — Workspace scanning
- `t/lsp/06_workspace_crossfile.t` — Cross-file workspace registration
- `t/lsp/07_crossfile_diagnostics.t` — Cross-file re-diagnosis on save
- `t/lsp/09_document_symbol.t` — DocumentSymbol provider
- `t/lsp/10_definition.t` — Go to Definition
- `t/lsp/11_signature_help.t` — Signature Help
- `t/lsp/12_inlay_hints.t` — Inlay Hints
- `t/lsp/13_references.t` — Find References
- `t/lsp/14_rename.t` — Rename
- `t/lsp/15_code_actions.t` — Code Actions (quick fixes)
- `t/lsp/16_semantic_tokens.t` — Semantic Tokens
- `t/critic/00_policy.t` — Perl::Critic policy bridge
- `t/critic/01_annotation_style.t` — Annotation style policy
- `t/critic/02_effect_completeness.t` — Effect completeness policy
- `t/critic/03_exhaustiveness.t` — Match exhaustiveness policy
