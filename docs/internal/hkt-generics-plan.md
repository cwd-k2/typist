# HKT Generics for datatype, struct, effect

> Higher-kinded type parameters on data declarations: `datatype 'Fix[F: * -> *]'`, `struct 'Wrapped[F: * -> *, T]'`, `effect 'Collect[F: * -> *]'`.

## Overview

```
Stage 0: Kind Parser                Stage 1: Declaration Kind Registration
(parenthesized kinds)               (auto-compute + register)
         │                                     │
         └───────────────┬─────────────────────┘
                         │
               Stage 2: Kind-Checked Instantiation
               (validate type args at application sites)
                         │
         ┌───────────────┼───────────────┐
         │               │               │
   Stage 3:        Stage 4:        Stage 5:
   Datatype HKT    Struct HKT     Effect HKT
   (Fix, Free)     (HKD)          (Collect)
         │               │               │
         └───────────────┼───────────────┘
                         │
               Stage 6: Unification Enhancement
               (higher-order pattern fragment)
                         │
               Stage 7: Runtime Support
               (type constructor as _type_arg)
```

## Progress

| Stage | Status | Notes |
|-------|--------|-------|
| 0. Kind Parser | ☐ todo | Parenthesized kinds: `(* -> *) -> *` |
| 1. Declaration Kind Registration | ☐ todo | Auto-compute kind from parameter kinds |
| 2. Kind-Checked Instantiation | ☐ todo | Validate type arg kinds at application sites |
| 3. Datatype HKT | ☐ todo | `datatype 'Fix[F: * -> *]'` |
| 4. Struct HKT | ☐ todo | `struct 'Wrapped[F: * -> *, T]'` |
| 5. Effect HKT | ☐ todo | `effect 'Collect[F: * -> *]'` |
| 6. Unification Enhancement | ☐ todo | Higher-order pattern unification |
| 7. Runtime Support | ☐ todo | Type constructor values in `_type_args` |

---

## Motivation

### What HKT generics enable

**Datatype**:
```perl
# Fixed-point type — enables recursion schemes (cata, ana, hylo)
datatype 'Fix[F: * -> *]' => {
    In => 'F[Fix[F]]'
};

# Free monad — effects as data
datatype 'Free[F: * -> *, A]' => {
    Pure   => 'A',
    Impure => 'F[Free[F, A]]'
};
```

**Struct** (Higher-Kinded Data pattern):
```perl
# Same shape, different interpretation:
#   UserF[Identity] = concrete record
#   UserF[Maybe]    = partial form (validation)
#   UserF[Const[Str]] = schema / labels
struct 'UserF[F: * -> *]' => (
    name  => 'F[Str]',
    age   => 'F[Int]',
    email => 'F[Str]',
);
```

**Effect**:
```perl
# Collection operations parameterized by container shape
effect 'Collect[F: * -> *]' => +{
    empty  => '<A>() -> F[A]',
    append => '<A>(F[A], F[A]) -> F[A]',
};
```

### What already exists

| Component | HKT Status |
|-----------|------------|
| Kind system (`Kind.pm`) | `*`, `Row`, `Arrow` — no parenthesized grouping |
| Kind parser | Right-assoc `* -> *` only; `(* -> *) -> *` not parsed |
| KindChecker | `infer_kind` handles Var base; `check_application` for string bases |
| Parser (`parse_param_decls`) | Recognizes `F: * -> *` syntax, stores `var_kind` |
| Type::Param | Supports Var base (`F[T]`), `has_var_base`, substitute normalizes |
| Unify | HKT Var base binding in both `unify` and `collect_bindings` |
| Typeclass | Full HKT: `Functor => 'F: * -> *'` with instance resolution |
| Datatype/Struct/Effect | Kind `*` parameters only |

### Relationship to GADT

HKT and GADT are **orthogonal**.

- **GADT**: parameters are kind `*`, but constructors refine return types (`IntLit -> Expr[Int]`)
- **HKT**: parameters themselves are higher-kinded (`F: * -> *`)

Combination (HKT + GADT) is theoretically possible but deferred. This plan addresses HKT alone.

---

## Stage 0: Kind Parser — Parenthesized Kinds

**Goal**: `Kind->parse('(* -> *) -> *')` returns `Arrow(Arrow(Star, Star), Star)`.

Currently `_parse_primary` only accepts `*` and `Row`. Add `(` to trigger recursive parse with closing `)`.

### Tasks

- [ ] 0.1 `Kind._parse_primary` — handle `(` token: recursive `_parse_kind`, expect `)`
- [ ] 0.2 `Kind::Arrow.to_string` — already parenthesizes arrow-kinded LHS (no change needed)
- [ ] 0.3 Tests in `t/13b_kind_edge.t` — parenthesized parse round-trip

### Design

```perl
# In _parse_primary:
if ($tok eq '(') {
    my $inner = _parse_kind($tokens, $pos);
    die "Kind: expected ')'" unless $$pos < @$tokens && $tokens->[$$pos++] eq ')';
    return $inner;
}
```

Tokenization note: `split /\s+/` won't separate `(` from `*` in `(* -> *)`. Need to pre-tokenize parens.

```perl
# Revised tokenization in Kind->parse:
my @tokens = $expr =~ /([*()\w]+|->)/g;  # captures *, Row, (, ), ->
```

### Files

| File | Change |
|------|--------|
| `lib/Typist/Kind.pm` | `parse` tokenizer, `_parse_primary` paren handling |
| `t/13b_kind_edge.t` | Parenthesized kind tests |

### Test Cases

```
1. parse('(* -> *) -> *') → Arrow(Arrow(Star,Star), Star)
2. parse('(* -> *) -> * -> *') → Arrow(Arrow(Star,Star), Arrow(Star,Star))
3. parse('(* -> * -> *) -> *') → Arrow(Arrow(Star,Arrow(Star,Star)), Star)
4. parse('* -> *') unchanged (backward compat)
5. to_string round-trip: parse then to_string reproduces original
```

---

## Stage 1: Declaration Kind Registration

**Goal**: When a parameterized type is declared, compute and register its kind with `KindChecker`.

### Kind computation rule

Given parameters with kinds `k₁, k₂, ..., kₙ`, the declared type has kind `k₁ -> k₂ -> ... -> kₙ -> *`.

```
datatype 'Maybe[T]'           → T: *        → Maybe : * -> *           (already implicit)
datatype 'Fix[F: * -> *]'     → F: * -> *   → Fix   : (* -> *) -> *
struct   'Pair[T, U]'         → T: *, U: *  → Pair  : * -> * -> *     (already implicit)
struct   'Wrapped[F: * -> *, T]' → ...       → Wrapped : (* -> *) -> * -> *
effect   'Collect[F: * -> *]' → F: * -> *   → Collect : (* -> *) -> Row
```

Note: effects produce `Row`, not `*`. The result kind for effect declarations is `Row`.

### Tasks

- [ ] 1.1 `_compute_declaration_kind(\@param_kinds, $result_kind)` — utility, folds params into Arrow
- [ ] 1.2 `Algebra._datatype` — after parsing generics, compute + register kind
- [ ] 1.3 `StructDef._struct` — after `parse_generic_decl`, compute + register kind
- [ ] 1.4 `EffectDef._effect` — after parsing type params, compute + register kind (result = `Row`)
- [ ] 1.5 `Registration.register_datatypes` — static path: register kind
- [ ] 1.6 `Registration.register_structs` — static path: register kind
- [ ] 1.7 `Registration.register_effects` — static path: register kind
- [ ] 1.8 Tests: kind lookup after declaration

### Design

```perl
# Utility (in KindChecker or shared):
sub compute_declaration_kind ($class, $param_kinds, $result_kind) {
    my $kind = $result_kind;  # Star for types, Row for effects
    for my $pk (reverse @$param_kinds) {
        $kind = Typist::Kind->Arrow($pk, $kind);
    }
    $kind;
}
```

Parameter kind extraction from `parse_generic_decl` results:

```perl
for my $g (@generics) {
    push @param_kinds, $g->{var_kind} // Typist::Kind->Star;
}
```

### Files

| File | Change |
|------|--------|
| `lib/Typist/KindChecker.pm` | `compute_declaration_kind` |
| `lib/Typist/Algebra.pm` | Register kind after datatype definition |
| `lib/Typist/StructDef.pm` | Register kind after struct definition |
| `lib/Typist/EffectDef.pm` | Register kind after effect definition |
| `lib/Typist/Static/Registration.pm` | Register kind in static paths (3 sites) |

---

## Stage 2: Kind-Checked Instantiation

**Goal**: When `Fix[Maybe]` appears in code, verify that `Maybe` has kind `* -> *` matching `Fix`'s first parameter.

### Current behavior

`check_application('Fix', @arg_kinds)` looks up `CONSTRUCTOR_KINDS{Fix}`. If not registered → gradual (assume `*`). After Stage 1, `Fix` will be registered with `(* -> *) -> *`, so `check_application` **already works** — it peels the first Arrow (`* -> *`) and checks the argument kind against it.

### Tasks

- [ ] 2.1 Verify `check_application` handles higher-kinded parameter kinds (may need no code change)
- [ ] 2.2 Static Checker: propagate kind errors as `KindError` diagnostics for HKT contexts
- [ ] 2.3 Tests: `Fix[Int]` → KindError (Int is `*`, expected `* -> *`)
- [ ] 2.4 Tests: `Fix[Maybe]` → OK (Maybe is `* -> *`)
- [ ] 2.5 Tests: `Wrapped[ArrayRef, Int]` → OK

### Potential issue: kind of user-defined types

When checking `Fix[Maybe]`, we need `Maybe`'s kind. If `Maybe` is registered (Stage 1), `constructor_kind('Maybe')` returns `* -> *`. If not registered, gradual kinding gives `*` → false KindError.

**Resolution**: Stage 1 must register all parameterized type kinds. Existing builtins (`ArrayRef`, `Maybe`, etc.) are already registered.

### Files

| File | Change |
|------|--------|
| `lib/Typist/KindChecker.pm` | Possibly no change (verify behavior) |
| `lib/Typist/Static/Checker.pm` | KindError diagnostic for HKT arity |
| `t/13b_kind_edge.t` or new test | HKT instantiation kind checks |

---

## Stage 3: Datatype HKT

**Goal**: `datatype 'Fix[F: * -> *]' => { In => 'F[Fix[F]]' }` works end-to-end.

### Runtime path (`Algebra.pm`)

Current `_datatype` extracts type params via `parse_parameterized_name` and stores names. For HKT:

1. Parse kind annotations: `parse_param_decls` already returns `var_kind` for `F: * -> *`
2. Store parameter kinds alongside names (new field or lookup via KindChecker after Stage 1)
3. Constructor spec parsing: `parse_constructor_spec('F[Fix[F]]', type_params => ['F'])` must promote `F` to `Var('F')`. Currently promotes Alias nodes matching param names — this works because `F` in `F[Fix[F]]` is parsed as `Alias('F')` which becomes `Var('F')`
4. The resulting type `Param(Var('F'), [Param('Fix', [Var('F')])])` is structurally correct

**Runtime inference challenge**: When `In(Some(In(None())))` is called, inferring `F` from the argument requires decomposing `Maybe[Fix[Maybe]]` against `F[Fix[F]]`. This is a unification problem (see Stage 6). For Stage 3, runtime inference can be **deferred** — require explicit type annotation or skip runtime HKT arg inference.

### Static path (`Registration.pm`)

1. `register_datatypes`: call `parse_generic_decl` (currently skipped for datatypes — they use unbounded generics only). For HKT, need to parse kind annotations
2. Store `var_kind` in generics passed to constructor functions
3. Constructor return type: `Param('Fix', [Var('F')])` — already handled

### Tasks

- [ ] 3.1 `Algebra._datatype` — call `parse_param_decls` on raw specs to extract `var_kind`
- [ ] 3.2 `Algebra._datatype` — pass kind info to `register_kind` (delegates to Stage 1)
- [ ] 3.3 Verify `parse_constructor_spec` handles `F[Fix[F]]` with F as HKT param
- [ ] 3.4 `Registration.register_datatypes` — call `parse_generic_decl` for kind-annotated params
- [ ] 3.5 Runtime constructor: defer HKT type arg inference (allow explicit annotation only)
- [ ] 3.6 Tests: `t/21_datatype.t` — `Fix[F: * -> *]` declaration and pattern match
- [ ] 3.7 Tests: `t/static/` — static analysis of `Fix[Maybe]` constructor calls

### Files

| File | Change |
|------|--------|
| `lib/Typist/Algebra.pm` | `_datatype`: parse kind annotations, register kind |
| `lib/Typist/Static/Registration.pm` | `register_datatypes`: `parse_generic_decl` for HKT |
| `lib/Typist/Static/Extractor.pm` | Store `type_param_specs` for datatypes (like structs) |
| `t/21_datatype.t` | HKT datatype tests |
| `t/static/` | Static analysis tests |

### Example: Fix

```perl
use Typist;

# ListF is the "shape" of a list, without recursion
datatype 'ListF[A, R]' => {
    NilF  => '()',
    ConsF => '(A, R)',
};

# Fix ties the recursive knot
datatype 'Fix[F: * -> *]' => {
    In => 'F'     # F applied to Fix[F], but simplified as just F for the constructor arg
};

# Note: the constructor stores one value of type F[Fix[F]],
# but since F is higher-kinded, the actual argument type depends on instantiation.
```

### Design note: constructor spec for HKT

The spec string `'F[Fix[F]]'` in the variant definition means the constructor takes one argument of type `F[Fix[F]]`. When `F` is in `type_params`, `parse_constructor_spec` promotes it to `Var('F')`, producing:

```
Param(Var('F'), [Param('Fix', [Var('F')])])
```

This is well-formed. Substitution with `F := Atom('Maybe')` yields:

```
Param('Maybe', [Param('Fix', [Atom('Maybe')])])
```

via `Param.substitute` → `_extract_base_name(Atom('Maybe'))` → `'Maybe'` (string). This normalization path already exists.

---

## Stage 4: Struct HKT

**Goal**: `struct 'Wrapped[F: * -> *, T]' => (value => 'F[T]')` works end-to-end.

### Existing infrastructure

`StructDef._struct` already calls `parse_generic_decl`, which parses `F: * -> *` and returns `var_kind`. The gap is:

1. `var_kind` is currently ignored (only `bound_expr` and `tc_constraints` are used)
2. Kind registration not performed (Stage 1 fills this)
3. Field type parsing: `'F[T]'` → `Param(Alias('F'), [Alias('T')])`. If `F` and `T` are in type params, Alias → Var promotion must happen in field type context (not just constructor spec)

### Field type Var promotion

Currently, struct field types are raw strings stored in the struct definition. At registration time, `Parser->parse('F[T]')` produces `Param(Alias('F'), [Alias('T')])`. The Alias-to-Var promotion happens in `parse_constructor_spec` (datatype) but **not** in struct field parsing.

**Options**:
1. Add Alias→Var promotion to struct field parsing (mirror `parse_constructor_spec`)
2. Treat Alias nodes as "maybe-Var" and resolve at substitution/unification time

Option 1 is cleaner. Add a `promote_params_to_vars($type, \@param_names)` utility to `Type::Fold` or similar.

### Tasks

- [ ] 4.1 `promote_params_to_vars` utility — walk type tree, Alias matching param name → Var
- [ ] 4.2 `StructDef._struct` — use `var_kind` from `parse_generic_decl` for registration
- [ ] 4.3 `StructDef._struct` — promote field type Alias → Var for HKT params
- [ ] 4.4 `Registration.register_structs` — promote field types, register kind
- [ ] 4.5 `CallChecker._check_struct_constructor_call` — kind check on type args
- [ ] 4.6 Runtime: same deferral as datatype (no HKT type arg inference)
- [ ] 4.7 Tests: `Wrapped[F: * -> *, T]` declaration, `Wrapped[Maybe, Int]` instantiation

### Files

| File | Change |
|------|--------|
| `lib/Typist/Type/Fold.pm` | `promote_params_to_vars` (or new utility) |
| `lib/Typist/StructDef.pm` | Use `var_kind`, promote field types |
| `lib/Typist/Static/Registration.pm` | Promote field types, register kind |
| `lib/Typist/Static/CallChecker.pm` | Kind check on struct constructor type args |
| `t/25_struct.t` | HKT struct tests |
| `t/static/11_struct.t` | Static analysis tests |

### Example: HKD (Higher-Kinded Data)

```perl
use Typist;

# Identity "container" — just wraps a value
newtype Identity => 'Any';

struct 'UserF[F: * -> *]' => (
    name  => 'F[Str]',
    age   => 'F[Int]',
    email => 'F[Str]',
);

# Concrete user: UserF[Identity] ≈ { name: Str, age: Int, email: Str }
# Partial user:  UserF[Maybe]    ≈ { name: Maybe[Str], age: Maybe[Int], ... }
```

---

## Stage 5: Effect HKT

**Goal**: `effect 'Collect[F: * -> *]' => +{ ... }` with `![Collect[ArrayRef]]` in annotations.

### Current parameterized effect model

Effects already support type parameters: `effect 'State[S]' => +{ get => '() -> S' }`. Row labels are strings: `"State[Int]"`. The label `"State[Int]"` is matched by string equality.

For HKT, the label becomes `"Collect[ArrayRef]"` where `ArrayRef` is a type constructor, not a concrete type. **String-based matching still works** — `"Collect[ArrayRef]"` is compared as a string.

### Kind tracking in effect ops

Operation signatures like `'<A>() -> F[A]'` reference the effect-level type parameter `F`. Currently, effect ops inherit the effect's `type_params` as additional generics. For HKT, the kind of `F` must be propagated to the operation's generics.

### Row label kind ambiguity

`"Collect[ArrayRef]"` vs `"State[Int]"` — syntactically identical but the argument has different kinds. This doesn't matter for string-based label matching, but **does matter for kind checking at the annotation site**.

When checking `:sig(() -> Void ! Collect[ArrayRef])`, the kind checker must:
1. Look up `Collect`'s kind: `(* -> *) -> Row`
2. Look up `ArrayRef`'s kind: `* -> *`
3. Verify application: `(* -> *) -> Row` applied to `* -> *` = `Row` ✓

### Tasks

- [ ] 5.1 `EffectDef._effect` — parse `var_kind` for HKT params, register kind
- [ ] 5.2 `Registration.register_effects` — propagate `var_kind` to op generics
- [ ] 5.3 `EffectChecker` — kind check on effect row label type arguments
- [ ] 5.4 `Checker._check_effect_wellformed` — validate HKT label args
- [ ] 5.5 Tests: `effect 'Collect[F: * -> *]'` definition and `![Collect[ArrayRef]]` annotation

### Files

| File | Change |
|------|--------|
| `lib/Typist/EffectDef.pm` | Parse `var_kind`, register kind |
| `lib/Typist/Static/Registration.pm` | Propagate kind to effect op generics |
| `lib/Typist/Static/EffectChecker.pm` | Kind check on labels |
| `lib/Typist/Static/Checker.pm` | Effect wellformedness with HKT |
| `t/15b_effects_generic.t` | HKT effect tests |
| `t/static/04b_effects_generic.t` | Static HKT effect tests |

---

## Stage 6: Unification Enhancement

**Goal**: Robust higher-order pattern unification for HKT type argument inference.

### Current state

`Unify.pm` already handles basic HKT unification:

```
Formal: Param(Var('F'), [Var('T')])     # F[T]
Actual: Param('Maybe', [Atom('Int')])   # Maybe[Int]
Result: { F => Atom('Maybe'), T => Atom('Int') }
```

This works because the Var base branch binds `F` to `Atom('Maybe')`, then recursively unifies params.

### What needs enhancement

**Nested HKT patterns**:
```
Formal: Param(Var('F'), [Param('Fix', [Var('F')])])   # F[Fix[F]]
Actual: Param('Maybe', [Param('Fix', [Atom('Maybe')])])  # Maybe[Fix[Maybe]]
```

This should bind `F := Atom('Maybe')` and verify consistency. The current `unify` handles this: it binds `F` from the base, then recursively unifies `Fix[F]` with `Fix[Maybe]`, finding `F` already bound to `Maybe` — consistent via `common_super`.

**Pattern fragment restriction**: Unification is decidable when:
- Type variables in the formal are applied only to distinct bound variables or concrete types
- No variable appears as both a base and a parameter

The current implementation naturally enforces this by structural recursion. No explicit fragment check is needed — ill-formed patterns simply fail to unify (produce `undef`), which is safe under gradual typing.

### Potential enhancement: decomposition of saturated applications

```
Formal: Var('F')                      # Just F (no application)
Actual: Param('Maybe', [Atom('Int')]) # Maybe[Int]
```

Should this bind `F := Maybe[Int]` (kind `*`) or is it ambiguous? If `F: * -> *`, the expected binding would be `F := Maybe` — but then `F` is unsaturated. If `F: *`, binding to `Maybe[Int]` is correct.

**Decision**: Use kind information to disambiguate. If `F: *`, bind to the whole type. If `F: * -> *`, this is a kind error (cannot bind a `* -> *` variable to a `*` value without application). This keeps the system predictable.

### Tasks

- [ ] 6.1 Verify nested HKT unification works with current code
- [ ] 6.2 Add kind-aware binding validation in `unify` (optional: check bound type's kind matches variable's kind)
- [ ] 6.3 Tests: nested HKT unification (`F[Fix[F]]` vs `Maybe[Fix[Maybe]]`)
- [ ] 6.4 Tests: kind mismatch in binding (`F: * -> *` vs `Atom('Int')`)
- [ ] 6.5 `collect_bindings`: same enhancements

### Files

| File | Change |
|------|--------|
| `lib/Typist/Static/Unify.pm` | Optional kind validation on bindings |
| `t/static/` | Unification tests for nested HKT |

---

## Stage 7: Runtime Support

**Goal**: `-runtime` mode correctly validates HKT-parameterized values.

### Challenge: type constructors in `_type_args`

Currently `_type_args` stores concrete `Type` objects (kind `*`):
```perl
$obj->{_type_args} = [Typist::Type::Atom->new('Int')];  # State[Int]
```

For HKT, `_type_args` must store type constructors (kind `* -> *`):
```perl
$obj->{_type_args} = [Typist::Type::Atom->new('Maybe')];  # Fix[Maybe]
```

`Atom('Maybe')` is kind `*` by default, but represents a `* -> *` constructor. The Atom itself doesn't carry kind information.

### Options

**Option A: Atom with kind annotation**

Add optional `kind` field to `Type::Atom`:
```perl
Typist::Type::Atom->new('Maybe', kind => Kind->parse('* -> *'))
```

Pro: Minimal change, kind info available where needed.
Con: Atoms are value-compared by name; kind field adds complexity to equality.

**Option B: Use Alias with kind**

`Type::Alias` already represents "a reference to a named type". Could carry kind.

Pro: Semantic fit (it's a reference to a type constructor, not a concrete type).
Con: Alias is currently used for unresolved names; dual purpose is confusing.

**Option C: Defer runtime HKT validation**

Skip runtime type arg inference for HKT parameters. Runtime structural checks (arity, field presence) still work. Full type validation for HKT args is a static-analysis concern.

Pro: No runtime complexity. Consistent with static-first philosophy.
Con: `-runtime` is less complete for HKT types.

**Recommendation**: **Option C** for initial implementation. The static-first architecture means most HKT errors are caught at compile time. Runtime can validate structural invariants without decomposing HKT type args. Option A can be added later if runtime HKT validation proves necessary.

### Tasks

- [ ] 7.1 `Algebra._datatype` — skip type arg inference for HKT params in constructors (guard on `var_kind`)
- [ ] 7.2 `StructDef._struct` — same skip for HKT params
- [ ] 7.3 `Type::Data.contains` — handle Var-base types in substituted specs gracefully
- [ ] 7.4 Document: HKT type args are not runtime-inferred (static-only validation)

### Files

| File | Change |
|------|--------|
| `lib/Typist/Algebra.pm` | Guard HKT params in runtime inference |
| `lib/Typist/StructDef.pm` | Guard HKT params in runtime inference |
| `lib/Typist/Type/Data.pm` | Graceful handling of HKT in `contains` |

---

## Key Design Decisions

### 1. HKT parameters are invariant

No subtyping on HKT type arguments. `Fix[ArrayRef]` and `Fix[Iterable]` are unrelated types.

**Rationale**: Variance for higher-kinded parameters requires tracking how the type constructor is used (covariant/contravariant position analysis at the kind level). This is complex and interacts badly with F-sub decidability. Invariance is the standard choice (Haskell, Rust, Scala).

### 2. Gradual kinding preserved

Unknown type constructors default to kind `*`. This means `Fix[UnknownType]` is accepted without error if `UnknownType` is not registered.

**Rationale**: Consistency with the existing gradual typing philosophy. Strict kinding can be enforced via `-strict` flag in future.

### 3. String-based row labels maintained

Effect row labels remain strings (`"Collect[ArrayRef]"`). HKT arguments in labels are opaque to the row system.

**Rationale**: Row polymorphism operates on label identity (set membership), not on label structure. `"Collect[ArrayRef]"` and `"Collect[HashRef]"` are simply different labels. Kind checking happens at annotation parse time, not at row operations.

### 4. Runtime HKT validation deferred (Option C)

Runtime (`-runtime`) does not infer or validate HKT type arguments. Structural checks remain.

**Rationale**: HKT type arg inference requires higher-order unification at runtime, which is expensive and complex. Static analysis covers the safety gap. This aligns with the static-first architecture.

### 5. No kind polymorphism

Kind variables (`k` in `F: k`) are not supported. All kind annotations are concrete.

**Rationale**: Kind polymorphism (System F-omega) is a significant leap in complexity. The current three-kind system (`*`, `Row`, `Arrow`) with explicit annotations covers practical use cases. Kind polymorphism can be considered as a future extension.

### 6. Type::Param.substitute normalization

When `Var('F')` is substituted with `Atom('Maybe')`, the result `Param(Atom('Maybe'), [...])` is normalized to `Param('Maybe', [...])` via `_extract_base_name`. This existing mechanism handles HKT substitution correctly.

**Invariant**: After substitution, `Param` bases are always strings (never Atom/Var objects). This is enforced by `_extract_base_name` in `Type::Param.substitute`.

---

## Interaction with Existing Features

### Typeclass constraints on HKT params

```perl
# Not initially supported:
struct 'FunctorBox[F: (* -> *) + Functor]' => (value => 'F[Int]');
```

Typeclass constraints on HKT parameters (e.g., "F must be a Functor") require the constraint classification system to handle kind `* -> *` typeclass variables. This is **deferred** — initial HKT generics support kind annotations (`F: * -> *`) and bounds (`T: Num`) but not HKT typeclass constraints.

### Bounded quantification

`F: * -> *` is a **kind constraint**, not a bounded quantification (which is `T: Num`, a type-level bound). These are orthogonal and coexist in the `parse_generic_decl` output:

```perl
# Kind constraint + type bound:
# <F: * -> *, T: Num>(F[T]) -> F[T]
# parse_generic_decl returns:
# [ { name => 'F', var_kind => Arrow(Star,Star) },
#   { name => 'T', bound_expr => 'Num' } ]
```

### Scoped effects

Scoped effects (`scoped 'State[Int]'`) create `EffectScope` tokens. For HKT effects like `Collect[ArrayRef]`, scoped would produce `EffectScope::Collect` with the type constructor argument. This **requires** runtime representation of HKT args (Stage 7) and is deferred until then.

### LSP

- **Hover**: `Fix[Maybe]` should display kind information
- **Completion**: After `Fix[`, suggest type constructors with matching kind
- **Diagnostics**: `KindError` for mismatched HKT application
- **Semantic tokens**: HKT params (`F`) tokenized as `typeParameter` (already works)

LSP enhancements are not staged separately — they follow naturally from each stage's static analysis changes.

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Kind parser edge cases (nested parens) | Low | Comprehensive test cases in Stage 0 |
| `_extract_base_name` breaks for new Param shapes | Medium | Verify substitute normalization in Stage 3/4 |
| Gradual kinding causes false negatives | Low | Acceptable — consistent with philosophy |
| Runtime HKT deferred too long | Low | Static analysis covers safety; runtime is opt-in |
| Unification fails for complex nested HKT | Medium | Miller's fragment is sufficient; test thoroughly |
| `parse_constructor_spec` Alias→Var promotion incomplete | Medium | Test with multi-level nesting (`F[G[T]]`) |
| Effect row label parsing ambiguity | Low | String-based labels avoid structural decomposition |

---

## Dependency Order

```
Stage 0 ← (none)
Stage 1 ← Stage 0
Stage 2 ← Stage 1
Stage 3 ← Stage 1 + Stage 2
Stage 4 ← Stage 1 + Stage 2
Stage 5 ← Stage 1 + Stage 2
Stage 6 ← Stage 3 or Stage 4 (can be done in parallel with 3-5, tested against them)
Stage 7 ← Stage 3 + Stage 4 + Stage 5

Stages 3, 4, 5 are independent of each other.
Stage 6 can proceed in parallel once Stage 2 is done.
```

## Open Questions

1. **Should `datatype` support bounded + HKT?** E.g., `datatype 'Free[F: (* -> *) + Functor, A]'`. This requires typeclass constraints on HKT params. Deferred but architecturally interesting.

2. **Kind inference from usage**: Should `datatype 'Fix[F]' => { In => 'F[Fix[F]]' }` infer `F: * -> *` from the usage `F[...]`? Currently, explicit annotation is required. Usage-based kind inference adds complexity but improves ergonomics.

3. **Recursive kinds**: `datatype 'Mu[F: * -> *]'` where `Mu[F]` is itself used as a type of kind `*`. Is `Mu` usable as a type constructor argument? E.g., `F[Mu[F]]` — this works structurally but kind-checking the recursion requires care.

4. **`_type_args` representation long-term**: If Option C (defer runtime) proves insufficient, should we introduce a `TypeConstructor` runtime value type distinct from `Atom`?
