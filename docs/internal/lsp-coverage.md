# LSP Coverage Matrix

Static analysis capabilities vs LSP feature coverage.

> **Related documentation**: [architecture.md](architecture.md) (system overview) | [static-analysis.md](static-analysis.md) (diagnostic sources) | [Guide](../guide/index.md) (type system)

**Rule**: When adding or modifying static analysis features, update this document.
New analysis outputs must have corresponding LSP entries (or an explicit "N/A" with rationale).

Last updated: 2026-03-08

---

## 1. Analyzer Output → LSP Consumer Map

Every field returned by `Analyzer->analyze()` and its LSP consumers.

| Analyzer Output | LSP Consumer | Status |
|---|---|---|
| `diagnostics` | Server `_emit_diagnostics` → publishDiagnostics | Complete |
| `symbols` | Hover (`symbol_at`), InlayHints, DocumentSymbol, Definition (same-file) | Complete |
| `extracted` | Completion (generics), SemanticTokens, Hover (synthesis) | Complete |
| `registry` | Hover, Completion, Definition (cross-file), SignatureHelp | Complete |
| `protocol_hints` | InlayHints (state transition labels) | Complete |
| `inferred_effects` | InlayHints (unannotated function effect labels) | Complete |
| `inferred_fn_returns` | InlayHints (unannotated function return type labels) | Complete |
| `narrowed_accessors` | Hover (accessor chain type narrowing in defined() guards) | Complete |
| `infer_log` | Debug tools (`typist-infer-dump`) | N/A (internal) |
| `timings` | Bench/debug only (`bench/09_analyzer_phases.pl`) | N/A (internal) |

---

## 2. Diagnostic Kinds

All error kinds produced by static analysis and their LSP surface.

| Kind | Producer | Published | CodeAction | Notes |
|---|---|---|---|---|
| CycleError | Checker | Yes | — | |
| TypeError | Checker/Registration | Yes | — | |
| TypeMismatch | TypeChecker | Yes | Suggestion text + auto-edit | `data._suggestions`, `_expected_type`, `_actual_type` passed to CodeAction |
| ArityMismatch | TypeChecker | Yes | — | |
| ResolveError | Registration/Checker | Yes | — | |
| EffectMismatch | EffectChecker | Yes | Auto-edit (`![Label]` insertion) | |
| ProtocolMismatch | Checker/ProtocolChecker | Yes | — | |
| UndeclaredTypeVar | Checker | Yes | — | |
| UndeclaredRowVar | Checker | Yes | — | |
| UnknownEffect | Checker | Yes | — | |
| UnknownTypeClass | Checker | Yes | — | |
| UnknownType | Checker | Yes | — | |
| ImportHint | Analyzer | Yes | — | Type used in `:sig()` but defining package not imported |
| InvalidBound | Checker | Yes | — | |
| KindError | Checker | Yes | — | |
| GradualHint | Analyzer | Yes | — | Severity 5 (opt-in blame tracking for `Any` usage) |

---

## 3. Completion Contexts

### Type Annotation Completion (inside `:sig(...)`)

| Context | Candidates | Status |
|---|---|---|
| `type_expr` | Primitives, parametrics, `forall` snippet, workspace typedefs | Done |
| `generic` | Document-level generics + standard vars (T/U/V/K) | Done |
| `effect` | Workspace effect names | Done |
| `constraint` | Workspace typeclass names (bounded quantification) | Done |

### Code Completion (in code body)

Two context-detection APIs feed into code completion:

1. **`completion_context(line, col)`** — annotation-level context (returns string: `type_expr` / `generic` / `effect` / `constraint`). Drives type-name completion inside `:sig(...)`.
2. **`code_completion_at(line, col)`** — code-level context (returns hashref: `{ kind, var, prefix, ... }`). Drives struct-field, method, effect-op, and match-arm completion.

The server tries annotation context first, then falls back to code context (see `Server._handle_completion`).

| Context | Trigger Pattern | Candidates | Status |
|---|---|---|---|
| `record_field` | `$var->{` | Struct fields (filtered by prefix, with type detail) | Done |
| `method` | `$self->` | Same-package methods (with signature detail) | Done |
| `effect_op` | `Effect::` | Effect operations (with signature) | Done |
| Constructor (fallback) | uppercase word | `all_constructor_names` from Workspace | Done (basic) |
| Function name | bare word | Registry functions (same-package + imported) | Done |
| Match arm | `match $val,` | Datatype variant names (with snippets, excludes used) | Done |
| Handle handler | `handle { } Eff =>` | Effect operation stubs | **Not implemented** |
| Variable name | `$` prefix | In-scope variables from symbols | **Not implemented** |
| Cross-package method | `$obj->` (non-self) | Struct fields + `with` from inferred type | Done |

---

## 4. Hover

### Symbol Kinds

| Symbol Kind | Displayed Information | Status |
|---|---|---|
| `function` | `sub name<T>(params) -> Return !Effect` + modifiers | Done |
| `parameter` | `name: type` + "parameter of fn" | Done |
| `variable` | `name: type` + inferred/narrowed annotation | Done |
| `typedef` | `type name = type` | Done |
| `newtype` | `newtype name = type` | Done |
| `effect` | Tabular: operations with protocol transitions | Done |
| `typeclass` | `typeclass Name<T> { methods }` | Done |
| `datatype` | `datatype Name[T] = Variants` (with GADT return types) | Done |
| `struct` | `struct Name { fields }` | Done |
| `field` | `(struct) field?: type` | Done |
| `method` | `(struct) name(...) -> returns` | Done |
| `builtin_type` | `type Int` / `type ArrayRef[T]` + description + hierarchy | Done |
| `match` (keyword) | `match(target: type) -> result_type` | Done |
| `handle` (keyword) | `handle: result_type ![Effect1, ...]` | Done |

### Contextual Hover

| Context | Mechanism | Status |
|---|---|---|
| Accessor `$var->field` | `_resolver->resolve_accessor_hover` (type chain walking) | Done |
| Struct constructor key `Name(key => ...)` | `_resolve_struct_key_hover` (PPI tree → struct field lookup) | Done |
| Keyword `match` / `handle` | `_resolve_keyword_hover` (PPI sibling walk → type synthesis) | Done |

### Non-Code Suppression

Hover, go-to-definition, and completion are suppressed in non-code regions via PPI token detection:

| Region | Detection | Suppression |
|---|---|---|
| Comments (`# ...`) | `PPI::Token::Comment` — column-level check | Full |
| Pod (`=head1` ... `=cut`) | `PPI::Token::Pod` — line range check | Full |
| String literals (`"..."`, `'...'`, `qq{}`, `q{}`) | `PPI::Token::Quote::*` — position within token bounds | Full |
| Here-documents (`<<EOF`) | `PPI::Token::HereDoc` — body line range | Full |

**Exception**: Strings inside Typist declarations (`typedef`, `newtype`, `struct`, `effect`, `typeclass`, `instance`, `datatype`, `declare`, `protocol`) contain type expressions and are NOT suppressed. Detection: walk up PPI tree to the outermost `PPI::Statement`; if its first word is a Typist keyword, the string is a type expression.

**Rationale**: `_word_range_at` extracts words from raw text without PPI token-type awareness. Without these guards, bare words in comments/strings would match against the registry fallback path (builtins, cross-package types, constructors), producing false hover results. PPI does not decompose interpolated strings into sub-tokens, so `$var` inside `"text $var"` is also suppressed — this is acceptable since the hover would be imprecise (scope/position mismatch within string content).

### Cross-Package Resolution

| Source | Mechanism | Status |
|---|---|---|
| Functions | `Registry.search_function_by_name` | Done |
| Newtypes | `Registry.lookup_newtype` | Done |
| Effects | `Registry.lookup_effect` | Done |
| Typeclasses | `Registry.lookup_typeclass` (+ methods hash) | Done |
| Struct accessors | `_walk_accessor_chain` with type tracking | Done |

---

## 5. Go to Definition

| Target | Same-file | Cross-file | Status |
|---|---|---|---|
| Type definitions (alias, newtype, datatype, struct, effect, typeclass) | symbols scan | `Workspace.find_definition` | Done |
| Functions | symbols scan | `Workspace.find_definition` | Done |
| Datatype constructor → owning datatype | — | `Workspace.find_definition` (variants scan) | Done |
| Struct field → struct definition | `$var->field` type resolution | `Workspace.find_definition` (type name) | Done |
| Effect operation → effect definition | `Effect::op` qualified name parse | `Workspace.find_definition` (effect name) | Done |
| Typeclass method → typeclass definition | — | — | **Not implemented** |
| Local variable → declaration site | `definition_at` (first symbol match) | — | Partial (no scope awareness) |

---

## 6. Signature Help

| Call Context | Mechanism | Status |
|---|---|---|
| Function call `fn(` | `signature_context` + `find_function_symbol` | Done |
| Cross-package function | Registry `search_function_by_name` fallback | Done |
| Multi-line call | 20-line lookback | Done |
| Method call `$obj->method(` | Var type resolution → struct method sig | Done |
| Constructor call `Name(field =>` | Struct lookup → field parameters | Done |

---

## 7. Inlay Hints

| Hint Kind | Source | Status |
|---|---|---|
| Inferred variable type | `symbols` (kind=variable, inferred=1) | Done |
| Loop variable type | `symbols` (from `_collect_loop_var_types`) | Done |
| Callback parameter type | `symbols` (from `callback_param_types`) | Done |
| Protocol state transition | `protocol_hints` | Done |
| Inferred effects (unannotated fn) | `inferred_effects` | Done |
| Unannotated function return type | `inferred_fn_returns` (TypeChecker) | Done |

---

## 8. Code Actions

| Diagnostic Kind | Action Type | Status |
|---|---|---|
| EffectMismatch | Auto-edit: insert/append `![Label]` to `:sig()` | Done |
| TypeMismatch | Auto-edit: change `:sig()` type annotation | Done |
| ArityMismatch | — | **Not implemented** |
| Match exhaustiveness warning | Insert missing arms | **Not implemented** |
| Unannotated function | Add `:sig()` from inferred types | **Not implemented** |

---

## 9. Semantic Tokens

| Token Source | Token Type | Definition | Usage | Status |
|---|---|---|---|---|
| Type names (alias, newtype, datatype, struct) | `type` | Yes | In `:sig()` only | Partial |
| Generic parameters | `typeParameter` | Yes | In `:sig()` | Done |
| Functions | `function` | Yes | — | Definition only |
| Variables (annotated) | `variable` + `declaration` | Yes | — | Definition only |
| Keywords (typedef, newtype, etc.) | `keyword` | Yes | N/A | Done |
| Effect names | `enum` | Yes | — | Definition only |
| Typeclass names | `class` | Yes | — | Definition only |
| Datatype variant names | `enumMember` | Yes | — | Definition only |
| Struct field names | `property` + `readonly` | Yes | — | Definition only |
| Operators in `:sig()` | `operator` | Yes | N/A | Done |
| Constructor usage (code body) | `enumMember` / `function` | — | Yes (PPI scan) | Done |
| Effect operation usage (code body) | `enum` + `function` | — | Yes (PPI scan) | Done |
| Scoped effect string (type names) | `type` | — | Yes (PPI scan) | Done |

---

## 10. References / Rename

| Capability | Mechanism | Status |
|---|---|---|
| Same-file word search | `Document.find_references` (word boundary regex) | Done |
| Cross-file word search | `Workspace.find_all_references` | Done |
| Rename (all files) | Word boundary replace | Done |
| Scope-aware resolution | `find_scoped_references` (variable scope filtering) | Done (variables only) |

---

## 11. Known Limitations

| Area | Limitation | Rationale |
|------|-----------|-----------|
| Typeclass instance completeness | Static analysis registers instances but does not verify method completeness. Missing methods are only detected at runtime. | Cross-file instance ordering is non-deterministic; static registration stores existence only (empty methods hash). Completeness check requires all source files to be loaded, which is a runtime guarantee. |
| Diagnostics timing | Diagnostics are published on `didOpen` and `didSave`, not on every keystroke (`didChange`). Hover, completion, and inlay hints use lazy analysis and are always fresh. | Full PPI parse + type checking on every keystroke is prohibitively expensive for large files. Save-time diagnostics is a standard LSP pattern that balances responsiveness with performance. |
| String interpolation hover | Variables inside interpolated strings (`"text $var"`) do not show hover. All content within string tokens is uniformly suppressed. | PPI does not decompose string content into sub-tokens. Attempting partial hover within strings would require custom parsing of interpolation syntax and would produce imprecise results (scope/position mismatch). |
| Regex content | Words inside regex patterns (`/pattern/`, `m//`, `s///`, `qr//`) are not suppressed. | Regex content rarely contains identifiers that collide with registered types/functions. False positives are negligible in practice. |

---

## Legend

- **Done** — Fully implemented and tested
- **Partial** — Implemented but incomplete (details in Notes)
- **Not implemented** — Static analysis has the data, LSP feature not built
- **N/A** — Not applicable
