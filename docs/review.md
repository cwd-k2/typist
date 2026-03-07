# Typist Critical Review

A comprehensive critical review of the Typist project architecture, implementation, and documentation.

> **Related documentation**: [architecture.md](architecture.md) | [type-system.md](type-system.md) | [static-analysis.md](static-analysis.md) | [conventions.md](conventions.md) | [lsp-coverage.md](lsp-coverage.md)

Last updated: 2026-03-07

---

## Table of Contents

- [Executive Summary](#executive-summary)
- [Architecture Evaluation](#architecture-evaluation)
- [Type System Evaluation](#type-system-evaluation)
- [Static Analysis Evaluation](#static-analysis-evaluation)
- [LSP Server Evaluation](#lsp-server-evaluation)
- [Test Suite Evaluation](#test-suite-evaluation)
- [Documentation Evaluation](#documentation-evaluation)
- [Improvement Proposals](#improvement-proposals)
- [Conclusion](#conclusion)

---

## Executive Summary

Typist is an ambitious static type system for Perl 5.40+ with exceptionally high technical completeness. The implementation reflects deep knowledge of type theory, achieving a feature set comparable to TypeScript and Haskell—generics, HKT, type classes, algebraic effects, protocol checking—on top of Perl's standard attribute syntax.

**Key Strengths:**
- Static-first design with zero runtime overhead by default
- Comprehensive type constructs (Union, Intersection, Quantified, Row, Effects)
- Well-structured module separation with clear responsibilities
- Extensive test coverage with edge case isolation

**Primary Concerns:**
- Global state usage in several modules
- Covariance assumptions that may be unsound for mutable collections
- Incomplete LSP completion features for common use cases

---

## Architecture Evaluation

### Strengths

1. **Static-First Design Consistency**

   Runtime overhead is zero by default; `-runtime` enables opt-in enforcement. This is practical for gradual adoption.

2. **Clear Module Separation**

   Responsibilities are well-defined across modules:
   ```
   Parser → Registry → Subtype → Checker → TypeChecker → EffectChecker → ProtocolChecker
   ```

3. **Dual-Mode Registry**

   The Registry supports both singleton mode (CHECK phase) and instance mode (LSP), enabling seamless integration with both use cases.

4. **Effective Caching Strategies**

   - Parser: LRU cache with epoch-based eviction
   - Subtype: refaddr-based memoization with anchor retention
   - Both prevent unbounded memory growth while improving performance

### Concerns

1. **Global State Usage**

   Several modules rely on class-level state:

   ```perl
   # Static::Infer
   my @_CALLBACK_PARAMS;
   my %_CALLBACK_PARAMS_SEEN;

   # Handler
   my %EFFECT_STACKS;
   my @POP_ORDER;
   ```

   While comments note "single-threaded, so safe," this creates barriers for future parallelization or reentrancy requirements.

2. **Scattered Lazy Requires**

   ```perl
   require Typist::Inference;
   require Typist::Parser;
   ```

   Used to avoid circular dependencies, but makes inter-module dependencies implicit and harder to trace.

3. **Error Handling Inconsistency**

   - Some paths use `die` for exceptions
   - Others use `$errors->collect` for accumulation
   - The boundary between user-facing errors and internal system errors is sometimes unclear

---

## Type System Evaluation

### Strengths

1. **Comprehensive Subtyping**

   Complete handling of Union, Intersection, Quantified, Row, and Eff types with correct variance rules.

2. **Occurs Check Implementation**

   Infinite types are properly detected and rejected:
   ```perl
   # Reject T = ArrayRef[T]
   return 0 if !$actual->is_var && grep { $_ eq $name } $actual->free_vars;
   ```

3. **HKT Support**

   Kind annotations (`F: * -> *`) and variable bases are properly handled in unification.

4. **Rémy-style Row Unification**

   Effect row variables are unified correctly, enabling polymorphic effect handling.

### Concerns

1. **Covariance Assumption for Collections**

   ```perl
   # Subtype.pm:254-255
   # Covariant: ArrayRef[T] <: ArrayRef[U] iff T <: U
   return all { _check($sp[$_], $pp[$_], $registry) } 0 .. $#sp;
   ```

   Perl arrays are mutable, so true covariance is unsound. This should be documented as a "static approximation" with explicit caveats.

   **Example of unsoundness:**
   ```perl
   my $ints :sig(ArrayRef[Int]) = [1, 2, 3];
   my $nums :sig(ArrayRef[Num]) = $ints;  # Allowed by covariance
   push @$nums, 3.14;                      # Now $ints contains a Double
   ```

2. **CodeRef Variance Ambiguity**

   Function parameter contravariance is correctly implemented:
   ```
   (A)->R <: (B)->R iff B <: A
   ```

   However, the variance of parameters in `CodeRef[A -> R]` is not clearly documented.

3. **Literal Type Widening Timing**

   - `Literal(42, 'Int')` correctly subtypes to `Int`
   - Widening at variable declaration vs expression inference needs consistent documentation

---

## Static Analysis Evaluation

### Strengths

1. **PPI-Based Stability**

   No source filters; code is analyzed as standard Perl. This ensures compatibility and predictability.

2. **Seven-Phase Pipeline**

   Clear separation of concerns:
   ```
   Extractor → Registration → Visibility → Checker → TypeEnv → TypeChecker/EffectChecker/ProtocolChecker → Collection
   ```

3. **Narrowing Engine**

   Practical type narrowing for common patterns:
   - `defined($x)` narrows `T | Undef` to `T`
   - `$x isa Foo` narrows to `Foo`
   - `ref($x) eq 'TYPE'` narrows to the corresponding type

4. **Protocol Checker**

   Tracks effect state transitions as a finite state machine, detecting protocol violations statically.

### Concerns

1. **PPI Limitations**

   Anonymous sub signatures are parsed as `PPI::Token::Prototype`, not `PPI::Structure::List`. While documented in conventions.md, the workarounds add complexity.

2. **Cross-File Analysis Boundaries**

   - `workspace_registry` merge imports external type definitions
   - Dependency ordering is non-deterministic
   - TypeClass instance completeness checking is "deferred to runtime" as a compromise

3. **Inference Precision Trade-offs**

   ```perl
   # Static::Infer — many silent fallbacks
   return undef unless defined $element;
   ```

   Silent failures when inference is impossible bias toward false negatives (no error reported), potentially missing real issues.

4. **CallChecker Complexity**

   Methods like `_check_generic_call` have many code paths, increasing the risk of edge case gaps.

---

## LSP Server Evaluation

### Strengths

1. **Feature Coverage**

   Comprehensive implementation: Hover, Completion, Definition, SignatureHelp, SemanticTokens, CodeAction, InlayHints.

2. **Document-Level Analysis**

   `analyze()` runs per-file with efficient change tracking.

3. **Rich Diagnostics**

   Additional information (`expected_type`, `actual_type`, `suggestions`) enables meaningful quick fixes.

### Concerns

1. **Single-Threaded Assumption**

   ```perl
   local $SIG{PIPE} = 'IGNORE';
   ```

   Pipe disconnection is ignored, but handling of client disconnection during long analysis is unclear. May cause issues with large files.

2. **Incomplete Completion Contexts**

   Per `lsp-coverage.md`:
   - Function name (bare word): **Not implemented**
   - Variable name (`$` prefix): **Not implemented**

   These are among the most frequently used completion contexts.

3. **Missing Cross-Package Definitions**

   - TypeClass method → typeclass definition: **Not implemented**
   - Affects development experience in codebases using type classes extensively

---

## Test Suite Evaluation

### Strengths

1. **Comprehensive Coverage**

   60+ test files in `t/` with numbered ordering indicating dependency sequence.

2. **Edge Case Isolation**

   `*b_*.t` files separate edge cases from main functionality tests.

3. **E2E Smoke Test**

   Complete LSP protocol round-trip test validates integration.

### Concerns

1. **Limited Property-Based Testing**

   `t/30_property.t` exists, but type systems benefit significantly from QuickCheck-style approaches due to combinatorial explosion of type combinations.

2. **Subprocess Test Fragility**

   `t/20_check_diagnostics.t` and `t/26_check_cli.t` execute CHECK phase in separate processes. Environment-dependent flakiness is a risk.

---

## Documentation Evaluation

### Strengths

1. **Well-Structured**

   Seven files in `docs/` with appropriate cross-references.

2. **Practical Gotchas**

   `conventions.md` lists Perl-specific pitfalls with actionable fixes.

3. **LSP Coverage Matrix**

   Feature-to-implementation mapping is clear and trackable.

### Concerns

1. **Onboarding Gap**

   `docs/getting-started.md` exists but is only referenced from `CLAUDE.md`. A more prominent entry point would help newcomers.

2. **Scattered API Reference**

   POD is embedded in each module. A unified API documentation would improve discoverability.

3. **No Changelog**

   Version remains at `0.01` with no change history.

---

## Improvement Proposals

### High Priority

| Item | Description | Rationale |
|------|-------------|-----------|
| Covariance soundness note | Add explicit comment in `Subtype.pm` that covariance is a "static approximation, unsound for runtime mutable arrays" | Prevents user confusion about type safety guarantees |
| Basic completion | Implement bare word function name and `$` variable name completion | Most frequently used completion contexts |
| CHANGELOG | Introduce changelog tracking | Essential for version management and user communication |

### Medium Priority

| Item | Description | Rationale |
|------|-------------|-----------|
| Encapsulate global state | Bind `Infer`, `Handler` state to `Analyzer` context | Enables future parallelization, improves testability |
| Property-based testing | Expand with symmetry/transitivity tests for Subtype, round-trip tests for Parser | Catches edge cases in combinatorial spaces |
| Error message abstraction | Extract hardcoded English strings to message IDs | Prepares for internationalization |

### Low Priority

| Item | Description | Rationale |
|------|-------------|-----------|
| Incremental analysis | Implement diff-based analysis instead of full-file reanalysis | Improves LSP responsiveness for large files |
| LSP 4.x features | Add semantic token range requests, etc. | Follows protocol evolution |

---

## Conclusion

Typist is an unprecedented type system implementation in the Perl ecosystem, achieving high standards in design quality, test coverage, and documentation. The primary issues are "practical rough edges" (incomplete completion, global state) rather than fundamental type-theoretic problems.

With continued improvement, Typist has the potential to provide Perl what TypeScript provided for JavaScript: a path to safer, more maintainable code without abandoning the language's flexibility and ecosystem.

### Metrics Summary

| Aspect | Rating | Notes |
|--------|--------|-------|
| Type System Correctness | ★★★★☆ | Sound core, covariance caveat |
| Architecture | ★★★★☆ | Clean separation, some global state |
| Static Analysis | ★★★★☆ | Comprehensive, PPI limitations |
| LSP Server | ★★★☆☆ | Good coverage, missing basics |
| Test Suite | ★★★★☆ | Extensive, could use more property tests |
| Documentation | ★★★★☆ | Well-structured, needs API unification |

---

## Appendix: Files Reviewed

```
lib/Typist.pm
lib/Typist/Registry.pm
lib/Typist/Parser.pm
lib/Typist/Subtype.pm
lib/Typist/Inference.pm
lib/Typist/Effect.pm
lib/Typist/Handler.pm
lib/Typist/TypeClass.pm
lib/Typist/Algebra.pm
lib/Typist/Static/Analyzer.pm
lib/Typist/Static/TypeChecker.pm
lib/Typist/Static/EffectChecker.pm
lib/Typist/Static/ProtocolChecker.pm
lib/Typist/Static/Infer.pm
lib/Typist/Static/Unify.pm
lib/Typist/Static/NarrowingEngine.pm
lib/Typist/LSP/Server.pm
docs/*.md
t/**/*.t
```
