# Internals

Documentation for contributors working on Typist itself. These documents describe internal architecture, analysis algorithms, coding conventions, and LSP implementation status.

!!! note
    If you are looking to **use** Typist in your Perl projects, see the [Guide](../guide/index.md) instead.

## Documents

| Document | Content |
|----------|---------|
| [Architecture](architecture.md) | System lifecycle, module dependency graph, type node hierarchy, registry design, error system, LSP server architecture, runtime enforcement, module loading strategy |
| [Static Analysis](static-analysis.md) | Analyzer pipeline, extractor, structural checker, TypeChecker, EffectChecker, type inference, gradual typing semantics, cross-file support, diagnostic infrastructure |
| [Conventions](conventions.md) | Language and module conventions, type system patterns, syntax conventions, feature reference, namespace model, design principles, Perl gotchas |
| [LSP Coverage](lsp-coverage.md) | Analyzer output → LSP consumer map, diagnostic kinds, completion contexts, hover, definition, signature help, inlay hints, code actions, semantic tokens, references/rename |

## Design Plans

| Document | Content |
|----------|---------|
| [Scoped Effects](scoped-effects-plan.md) | Per-effect generics, effect discharge, scoped capability-based effects (completed) |
| [HKT Generics](hkt-generics-plan.md) | Higher-kinded type parameters on datatype, struct, effect declarations |
| [Associated Types & Indexed Protocols](indexed-protocols-plan.md) | Associated types on type classes, parameterized protocol states with type flow |
