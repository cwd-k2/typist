# CLAUDE.md

> AI assistance context. For complete documentation, see [docs/](docs/).

## Project Overview

Typist is a pure Perl type system for Perl 5.40+. Static-first architecture: errors are caught at compile time (CHECK phase) and via LSP, with runtime enforcement as opt-in. Supports generics, type classes, HKT, nominal types, recursive types, literal types, bounded quantification, and algebraic effects with row polymorphism.

## Architecture

```
Static-First (default)       Runtime (opt-in: -runtime)    LSP Layer         CLI
──────────────────────       ─────────────────────────     ──────────────    ──────────
Typist.pm (entry+CHECK)      Tie::Scalar                   LSP::Server       Check.pm
Static::Checker              Attribute._wrap_sub            LSP::Document
Static::Analyzer (CHECK)     Inference.pm                   LSP::Workspace
Static::TypeChecker          Handler (Effect::op/handle)    LSP::Hover
Static::EffectChecker                                       LSP::Completion
Static::Extractor                                           LSP::Transport
Static::Infer                                               LSP::CodeAction
Static::Unify                                               LSP::SemanticTokens
Static::SymbolInfo                                          LSP::Logger

Shared Infrastructure
──────────────────────────
Registry, Parser, Subtype, Transform, Attribute, Prelude
Error (value + Collector), Error::Global (singleton buffer)
Type::{Atom,Param,Union,Intersection,Func,Record,Struct,Var,Alias,Literal,Newtype,Row,Eff,Data}
Type::Fold (map_type, walk), Struct::Base, Newtype::Base
Kind, KindChecker, TypeClass, Effect, Static::Registration
DSL (Type constructors: Int, Str, Double, Num, Array, Hash, Record, optional, etc.)
```

## Validation Architecture

Typist の検証は3層に分かれる。設計原則は「静的解析を既定とし、型の境界は常に守り、ランタイム監視は選択的に」。

- **Layer 1 — Static Analysis** (compile time, always): PPI ベース。`Analyzer` が Extractor → Registration → Checker → TypeChecker → EffectChecker → ProtocolChecker を統括。CHECK ブロックがパッケージごとに実行。LSP は `Document->analyze` で差分実行。`TYPIST_CHECK_QUIET=1` で CHECK スキップ。
- **Layer 2 — Boundary Enforcement** (runtime, always-on): newtype/datatype/struct コンストラクタ + Effect::op ディスパッチの検証。`-runtime` に依存しない。コンストラクタは型の不変条件を確立する場。
- **Layer 3 — Runtime Monitoring** (opt-in: `-runtime` / `TYPIST_RUNTIME=1`): `Tie::Scalar` による `:sig()` 変数の代入監視。唯一 `-runtime` でゲートされる機構。

```
機構              | use Typist (default) | use Typist -runtime
──────────────────|──────────────────────|─────────────────────
Static Analysis   | ON                   | ON
CHECK diagnostics | ON                   | ON
Constructor 境界  | ON                   | ON
Effect dispatch   | ON                   | ON
Tie::Scalar 監視  | OFF                  | ON
```

## Documentation

- **[docs/type-system.md](docs/type-system.md)** — Type constructs, subtyping, gradual typing, narrowing, prelude
- **[docs/architecture.md](docs/architecture.md)** — System design, module graph, data flow, error system
- **[docs/static-analysis.md](docs/static-analysis.md)** — Analyzer pipeline, inference, type checking, effect checking
- **[docs/conventions.md](docs/conventions.md)** — Coding conventions, feature reference, Perl gotchas
- **[docs/lsp-coverage.md](docs/lsp-coverage.md)** — LSP feature matrix, diagnostic kinds
- **[docs/index.md](docs/index.md)** — Navigation hub

## Commands

```sh
mise run check             # Run typist-check static analysis
mise run deps              # Install dependencies
mise run test              # Run all tests (parallel)
mise run test:core         # Core type system tests
mise run test:static       # Static analysis tests
mise run test:lsp          # LSP server tests
mise run test:critic       # Perl::Critic policy tests
mise run test:e2e          # LSP E2E smoke test (subprocess)
mise run example           # Run all examples
```

## Test Structure

Tests are numbered and ordered by dependency:
- `t/00_compile.t` — Module loading
- `t/01_parser.t` — Type expression parsing
- `t/02_subtype.t` — Subtype relation
- `t/03_attribute.t` — Attribute-based type annotations
- `t/04_inference.t` — Type inference and unification
- `t/05_integration.t` — End-to-end scenarios
- `t/06_instance.t` — Instance-based Registry/Checker
- `t/06b_registry_unregister.t` — Registry unregister methods
- `t/07_multivar.t` — Multi-character type variables and Transform
- `t/08_literal.t` — Literal types
- `t/09_newtype.t` — Nominal types
- `t/10_recursive.t` — Recursive type definitions
- `t/11_bounded.t` — Bounded quantification
- `t/12_typeclass.t` — Type classes
- `t/13_hkt.t` — Higher-kinded types and Kind system
- `t/14_effects_foundation.t` — Effect/Row/Eff types
- `t/15_effects_row.t` — Row parsing, subtyping, unification
- `t/16_effects_attribute.t` — :Eff attribute, effect keyword
- `t/17_effects_integration.t` — End-to-end effect system
- `t/18_dsl.t` — Type DSL
- `t/19_fold.t` — Type::Fold
- `t/20_check_diagnostics.t` — CHECK-phase static analysis (subprocess)
- `t/21_datatype.t` — Algebraic data types
- `t/22_effects_handler.t` — Effect handlers
- `t/23_gadt.t` — GADT
- `t/24_rank2.t` — Rank-2 polymorphism
- `t/25_struct.t` — Nominal struct types
- `t/26_check_cli.t` — CLI typist-check (subprocess)
- `t/27_protocol.t` — Protocol FSM
- `t/28_selective_import.t` — Selective DSL export
- `t/static/00_extractor.t` — PPI-based type extraction
- `t/static/01_analyzer.t` — Static analysis pipeline
- `t/static/02_infer.t` — Static type inference
- `t/static/03_typecheck.t` — Static type mismatch detection
- `t/static/04_effects.t` — Static effect mismatch detection
- `t/static/05_extractor_advanced.t` — Advanced extraction
- `t/static/06_crossfile_analyzer.t` — Cross-file type resolution
- `t/static/07_method_typecheck.t` — Method type checking
- `t/static/08_prelude.t` — Builtin prelude
- `t/static/09_builtins_infer.t` — Typist builtin inference
- `t/static/10_rank2.t` — Rank-2 polymorphism static analysis
- `t/static/11_struct.t` — Struct static analysis
- `t/static/12_loop_inference.t` — Loop variable inference
- `t/static/13_hof_inference.t` — Higher-order function inference
- `t/static/14_protocol.t` — Protocol static analysis
- `t/static/15_ref_narrowing.t` — ref() type narrowing
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
- `t/lsp/15_code_actions.t` — Code Actions
- `t/lsp/16_semantic_tokens.t` — Semantic Tokens
- `t/lsp/17_protocol.t` — Protocol hover and inlay hints
- `t/lsp/18_symbol_info.t` — SymbolInfo factory functions
- `t/critic/00_policy.t` — Perl::Critic policy bridge
- `t/critic/01_annotation_style.t` — Annotation style policy
- `t/critic/02_effect_completeness.t` — Effect completeness policy
- `t/critic/03_exhaustiveness.t` — Match exhaustiveness policy
