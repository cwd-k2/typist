# CLAUDE.md

> AI assistance context. For complete documentation, see [docs/](docs/).

## Project Overview

Typist is a pure Perl type system for Perl 5.40+. Static-first architecture: errors are caught at compile time (CHECK phase) and via LSP, with runtime enforcement as opt-in. Supports generics, type classes, HKT, nominal types, recursive types, literal types, bounded quantification, and algebraic effects with row polymorphism.

## Architecture

```
Static-First (default)       Runtime (opt-in: -runtime)    LSP Layer         CLI
──────────────────────       ─────────────────────────     ──────────────    ──────────
Typist.pm (entry+CHECK)      Tie::Scalar                   LSP::Server       Check.pm
 ├ Definition.pm             Attribute._wrap_sub            LSP::Document†
 ├ Algebra.pm                Inference.pm                   LSP::Workspace
 ├ StructDef.pm              Handler (Effect::op/handle)    LSP::Hover
 ├ EffectDef.pm                                             LSP::Completion
 └ External.pm                                              LSP::Transport
Static::Checker                                             LSP::CodeAction
Static::Analyzer (CHECK)                                    LSP::SemanticTokens
Static::TypeEnv†                                            LSP::Logger
Static::TypeChecker (type checks)
Static::CallChecker
Static::NarrowingEngine
Static::EffectChecker
Static::ProtocolChecker
Static::Extractor
Static::Infer†
Static::Unify
Static::SymbolInfo

Shared Infrastructure
──────────────────────────
Registry, Parser, Subtype, Transform, Attribute, Prelude, Protocol
Error (value + Collector), Error::Global (singleton buffer)
Handler, EffectScope, Kind, KindChecker, TypeClass, Effect, Static::Registration
Type::{Atom,Param,Union,Intersection,Func,Record,Struct,Var,Alias,Literal,Newtype,Quantified,Row,Eff,Data}
Type::Fold (map_type, walk)

† = サブモジュールに分解されている（詳細は lib/ ツリー参照）
```

## Validation Architecture

Typist の検証は3層に分かれる。設計原則は「静的解析を既定とし、通常実行への負荷をゼロに、ランタイム検証は選択的に」。

- **Layer 1 — Static Analysis** (compile time, always): PPI ベース。`Analyzer` が 7フェーズで統括: Extractor → Registration → Checker → TypeEnv(環境構築) → TypeChecker/CallChecker(ファイルレベル検査) → 統一関数ループ(TypeChecker+EffectChecker+ProtocolChecker) → 収集。CHECK ブロックがパッケージごとに実行。LSP は `Document->analyze` で差分実行。`TYPIST_CHECK_QUIET=1` で CHECK スキップ。
- **Layer 2 — Structural Enforcement** (runtime, always-on): コンストラクタの構造検査（未知フィールド、必須フィールド欠損、引数アリティ）。安価で API 誤用を防ぐ。Effect/typeclass ディスパッチはメカニズムそのもの。
- **Layer 3 — Runtime Type Checking** (opt-in: `-runtime` / `TYPIST_RUNTIME=1`): コンストラクタ型検証（`contains`/`infer_value`/bounds/typeclass）、`Tie::Scalar` 変数監視、重量モジュール（Inference, Subtype）のロード。

```
機構                 | use Typist (default) | use Typist -runtime
─────────────────────|──────────────────────|─────────────────────
Static Analysis      | ON                   | ON
CHECK diagnostics    | ON                   | ON
構造検査 (arity等)   | ON                   | ON
Effect dispatch      | ON                   | ON
Typeclass dispatch   | ON                   | ON
Constructor 型検証   | OFF                  | ON
Tie::Scalar 監視     | OFF                  | ON
```

## Documentation

**[docs/index.md](docs/index.md)** — Navigation hub. 主要セクション:

- **[Getting Started](docs/getting-started/)** — Installation, first program, editor setup
- **[Guide](docs/guide/)** — Type annotations, structs, ADTs, generics, effects, typeclasses
- **[Advanced](docs/advanced/)** — Subtyping, narrowing, rank-2, HKT, recursive types
- **[Cookbook](docs/cookbook/)** — Domain modeling, multi-file, error handling, migration
- **[Reference](docs/reference/)** — Type syntax, diagnostics, prelude, environment variables
- **[Tooling](docs/tooling/)** — LSP, typist-check, debug tools, Perl::Critic policies
- **[Internals](docs/internal/)** — Architecture, static analysis pipeline, conventions, LSP coverage

## Commands

```sh
mise run check             # Run typist-check static analysis
mise run deps              # Install dependencies
mise run test              # Run all tests
mise run test:core         # Core type system tests
mise run test:static       # Static analysis tests
mise run test:lsp          # LSP server tests
mise run test:critic       # Perl::Critic policy tests
mise run test:e2e          # LSP E2E smoke test (subprocess)
mise run example           # Run all examples
```

## Test Structure

`t/NN_name.t` の番号順が依存順序。`b` suffix はエッジケース（例: `02b_subtype_edge.t`）。

| Directory | Scope | Notes |
|-----------|-------|-------|
| `t/` | Core type system | parser, subtype, inference, newtype, ADT, effects, struct, protocol |
| `t/static/` | Static analysis | extractor, analyzer, inference, type/effect/protocol check, narrowing, unify |
| `t/lsp/` | LSP server | transport, diagnostics, hover, completion, workspace, references, rename, semantic tokens |
| `t/critic/` | Perl::Critic | annotation style, effect completeness, match exhaustiveness |

`t/20_check_diagnostics.t`, `t/26_check_cli.t` は subprocess テスト（別プロセスで CHECK phase を実行）。
