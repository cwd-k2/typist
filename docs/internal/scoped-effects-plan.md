# Scoped Effects Implementation Plan

> Per-effect generics (`State[S]`), effect discharge, and scoped capability-based effects.

## Overview

```
Stage 1: Effect Discharge                Stage 2: Per-Effect Generics
(EffectChecker handle-aware)             (State[S] type-level)
         │                                        │
         └──────────────┬─────────────────────────┘
                        │
                  Stage 3: Scoped Effects
                  (scoped + capability dispatch)
                   ├─ 3a: Runtime
                   └─ 3b: Static analysis
```

## Progress

| Stage | Status | Notes |
|-------|--------|-------|
| 1. Effect Discharge | ✅ done | EffectChecker handle-aware. 7 tests added (33 total). 952 static tests pass |
| 2. Per-Effect Generics | ✅ done | Parser, Effect, EffectDef, Extractor, Registration, Checker, Row updated. 17 tests (10 type-level + 7 static). All 2917 tests pass |
| 3a. Scoped Runtime | ✅ done | EffectScope, Handler dual dispatch, handle scoped. 9 tests. All 2926 tests pass |
| 3b. Scoped Static | ✅ done (core) | TypeEnv inference + method resolution. 4 tests. LSP hover/completion deferred. All 2930 tests pass |

---

## Stage 1: Effect Discharge

**Goal**: EffectChecker recognizes `handle { body } E => +{...}` as consuming effect `E`.

**Typing rule**: `handle { body ![E, r] } E => {...} : ![r]`

### Tasks

- [x] 1.1 `_scan_handle_scopes($block)` — collect `{ body_node, effect_name }` from handle blocks
- [x] 1.2 `_is_discharged($word, $label, $scopes)` — ancestor chain check via refaddr
- [x] 1.3 `_collect_called_effects` — carry `word` token, filter by handled scope
- [x] 1.4 `infer_effects` — same filtering for LSP inlay hints
- [x] 1.5 Tests in `t/static/04_effects.t` — 7 new tests (27-33)

### Files

| File | Change |
|------|--------|
| `lib/Typist/Static/EffectChecker.pm` | `_scan_handle_scopes`, `_is_handled`, filter logic |
| `t/static/04_effects.t` | handle discharge tests |

### Test Cases

```
1. handle discharges single effect → no EffectMismatch
2. partial discharge (2 effects, 1 handled) → remaining checked
3. nested handle → inner discharge doesn't leak to outer
4. handle for wrong effect → no discharge
5. infer_effects accounts for handle discharge
```

---

## Stage 2: Per-Effect Generics

**Goal**: `effect 'State[S]' => +{ get => '() -> S', put => '(S) -> Void' }` with `![State[Int]]` in annotations.

**Design**: Row labels stored as strings (`"State[Int]"`). Concrete instantiations first; generic labels (`State[S]` with free vars) deferred.

### Tasks

- [x] 2.1 Parser `_parse_effect_row` — uppercase token + `[` = type parameter bracket, depth-tracked nested brackets
- [x] 2.2 Parser `parse_row` — regex `\w+(?:\[.+?\])?` for parameterized labels with protocol states
- [x] 2.3 `Effect.pm` — `type_params` field, `is_generic`
- [x] 2.4 `EffectDef._effect` — `parse_parameterized_name`, register under base name
- [x] 2.5 `Extractor._extract_effects` — decompose parameterized name, store `type_params`
- [x] 2.6 `Registration.register_effects` — pass `type_params` to Effect constructor
- [x] 2.7 `EffectDef._handle` — extract base name from parameterized spec
- [x] 2.8 `Row.label_base_name` utility (class method)
- [x] 2.9 `Checker._check_effect_wellformed` — extract base name before `is_effect_label`
- [x] 2.10 Tests: `t/15b_effects_generic.t` (10 tests), `t/static/04b_effects_generic.t` (7 tests)

### Files

| File | Change |
|------|--------|
| `lib/Typist/Parser.pm` | `_parse_effect_row`, `parse_row` |
| `lib/Typist/Effect.pm` | `type_params`, `is_generic` |
| `lib/Typist/EffectDef.pm` | `_effect` parameterized name |
| `lib/Typist/Type/Row.pm` | `_label_base_name` |
| `lib/Typist/Static/Extractor.pm` | `_extract_effects` |
| `lib/Typist/Static/Registration.pm` | `register_effects` |
| `lib/Typist/Static/Checker.pm` | `is_effect_label` |
| `t/15b_effects_generic.t` | new: type-level tests |
| `t/static/04b_effects_generic.t` | new: static analysis tests |

### Test Cases

```
1. Parser: ![State[Int]] → Row labels = ["State[Int]"]
2. Parser: ![State[Int], Console, r] → correct 3-element Row
3. Parser: ![State[Int]<Running>] → parameterized + protocol state
4. effect 'State[S]' definition → Effect.type_params = ['S']
5. Static: ![State[Int]] call matches ![State[Int]] decl
6. Static: ![State[Int]] vs ![State[Str]] → EffectMismatch
7. Runtime: handle { } 'State[Int]' => +{...} dispatches correctly
8. Subtype: Row(State[Int], Console) <: Row(State[Int])
```

---

## Stage 3a: Scoped Effects — Runtime

**Goal**: `scoped` capability tokens with identity-based handler dispatch.

### Tasks

- [x] 3a.1 `Handler.pm` — `%SCOPED_STACKS`, `push_scoped_handler`, `find_scoped_handler`, tagged POP_ORDER
- [x] 3a.2 `EffectScope.pm` — new module, base class with `_scope_id`, `effect_name`, `base_name`
- [x] 3a.3 `EffectDef._scoped` — per-effect subclass (`EffectScope::State`), dynamic method installation
- [x] 3a.4 `EffectDef._handle` — ref key → scoped push via `isa('Typist::EffectScope')`
- [x] 3a.5 `Typist.pm` — export `scoped`
- [x] 3a.6 Tests: `t/33_scoped_effects.t` (9 tests)

### Files

| File | Change |
|------|--------|
| `lib/Typist/EffectScope.pm` | new: capability token base class |
| `lib/Typist/Handler.pm` | `%SCOPED_STACKS`, `push/find_scoped_handler`, tagged POP_ORDER |
| `lib/Typist/EffectDef.pm` | `_scoped`, `_handle` ref dispatch |
| `lib/Typist/Typist.pm` | export `scoped` |
| `t/33_scoped_effects.t` | new: 9 tests |

### Test Cases

```
1. scoped 'State[Int]' → blessed EffectScope object
2. $counter->get() → scoped handler dispatch
3. Two instances of same effect → independent handlers
4. handle { } $counter => +{...} → scoped push/pop
5. Exception cleanup for scoped handlers
6. Name-based and scoped handlers coexist
```

---

## Stage 3b: Scoped Effects — Static Analysis

**Goal**: Static analysis support for `scoped` and scoped handle blocks.

### Tasks

- [x] 3b.1 `Infer._infer_call` — `scoped('State[Int]')` → `Atom('EffectScope[State]')`
- [x] 3b.2 `Infer._infer_method_access` — `$ref->get()` → effect op return type via registry
- [x] 3b.3 `Infer._extract_first_string_arg` — PPI Quote extraction from List node
- [x] 3b.4 Tests: `t/static/04c_scoped_effects.t` (4 tests)
- [ ] 3b.5 EffectChecker — `handle { } $ref => +{...}` scoped discharge (deferred)
- [ ] 3b.6 LSP Hover/Completion — EffectScope method support (deferred)

### Files

| File | Change |
|------|--------|
| `lib/Typist/Static/Infer.pm` | `_infer_call` (scoped), `_infer_method_access` (EffectScope ops) |
| `t/static/04c_scoped_effects.t` | new: 4 tests (inference, method resolution, mismatch, clean) |

---

## Design Notes

### Why no "consumption" annotation

Effect discharge is a typing rule, not an annotation. `handle` subtracts `E` from the row automatically. A function's `:sig()` expresses consumption by *absence* — if DB isn't in the output effects, it was consumed internally.

### Parser ambiguity: `[` in effect rows

`![State[Int]]` tokenizes as `[State, [, Int, ], ]`. The inner `[` is disambiguated by context: following an uppercase-initial token = type parameter; otherwise = row bracket.

### Scoped dispatch model

```
Name-based (existing):    State::get() → Handler.find_handler('State')
Identity-based (new):     $counter->get() → Handler.find_scoped_handler($counter._scope_id)
```

Dual dispatch coexists. Exn remains Perl-native (eval/die).

### String-based labels (Stage 2 trade-off)

Row labels like `"State[Int]"` are strings for backward compatibility. Structural decomposition via `parse_parameterized_name` when needed. Generic labels (`State[S]` with free vars in Row) require future work to store as `Type::Param` objects for proper `substitute`/`free_vars`.
