# Typist Documentation

Navigation hub for all Typist documentation.

## Reading Paths

**For users** (writing Typist-annotated Perl code):
1. [README](../README.md) — Installation, synopsis, quick start
2. [Type System Reference](type-system.md) — All type constructs, subtyping rules, DSL
3. Module POD — `perldoc Typist`, `perldoc Typist::DSL`, etc.

**For contributors** (working on Typist internals):
1. [Architecture](architecture.md) — System design, module graph, data flow
2. [Static Analysis](static-analysis.md) — Analyzer pipeline, inference, checking
3. [Conventions](conventions.md) — Coding conventions, feature reference, Perl gotchas
4. [LSP Coverage](lsp-coverage.md) — Feature matrix, diagnostic kinds

## Document Map

| Document | Content | Audience |
|----------|---------|----------|
| [README](../README.md) | Installation, synopsis, examples, editor integration | Users |
| [type-system.md](type-system.md) | Type constructs, subtyping, gradual typing, narrowing, prelude | Users, Contributors |
| [architecture.md](architecture.md) | System lifecycle, module dependency graph, error system, LSP | Contributors |
| [static-analysis.md](static-analysis.md) | Extractor, inference, type checking, effect checking, protocols | Contributors |
| [conventions.md](conventions.md) | Language conventions, type system patterns, Perl gotchas | Contributors |
| [lsp-coverage.md](lsp-coverage.md) | LSP feature matrix, diagnostic kinds, coverage tracking | Contributors |
| [CLAUDE.md](../CLAUDE.md) | AI assistance context (compact summary) | AI Tools |

## Topic Index

### Type System
- Primitive types, atoms, hierarchy — [type-system.md](type-system.md#primitive-types)
- Parameterized types (Array, Hash, Maybe, Tuple) — [type-system.md](type-system.md#parameterized-types)
- Union, Intersection — [type-system.md](type-system.md#union-types)
- Record (structural) vs Struct (nominal) — [type-system.md](type-system.md#record-types), [conventions.md](conventions.md#type-system-conventions)
- Generics and bounded quantification — [type-system.md](type-system.md#generics)
- Algebraic data types, GADT, enum, match — [type-system.md](type-system.md#algebraic-data-types)
- Type classes and HKT — [type-system.md](type-system.md#type-classes)
- Algebraic effects and protocols — [type-system.md](type-system.md#algebraic-effects)
- Gradual typing — [type-system.md](type-system.md#gradual-typing)
- Type narrowing — [type-system.md](type-system.md#type-narrowing)
- Builtin prelude — [type-system.md](type-system.md#builtin-prelude)

### Architecture
- Three validation layers — [architecture.md](architecture.md), [CLAUDE.md](../CLAUDE.md#validation-architecture)
- Static analysis pipeline — [static-analysis.md](static-analysis.md)
- Module dependency graph — [architecture.md](architecture.md#module-dependency-graph)
- Error system — [architecture.md](architecture.md#error-system)
- LSP server architecture — [architecture.md](architecture.md#lsp-architecture)

### Development
- Coding conventions — [conventions.md](conventions.md#language-and-module-conventions)
- Perl gotchas — [conventions.md](conventions.md#perl-gotchas)
- Commands (mise) — [CLAUDE.md](../CLAUDE.md#commands)
- Test structure — [CLAUDE.md](../CLAUDE.md#test-structure)
- LSP coverage tracking — [lsp-coverage.md](lsp-coverage.md)
