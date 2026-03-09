# Associated Types & Indexed Protocol FSM

> Associated types on type classes, and parameterized protocol states that carry type information through transitions.

## Overview

```
Stage 0: Associated Types              Stage 1: Associated Type Resolution
(typeclass declarations)               (inference + projection)
         │                                        │
         └──────────────┬─────────────────────────┘
                        │
                  Stage 2: Indexed Protocol States
                  (states carry type parameters)
                   ├─ 2a: Definition & Extraction
                   └─ 2b: State-Indexed Checking
                        │
                  Stage 3: Static Analysis Integration
                  (TypeChecker + EffectChecker)
                        │
                  Stage 4: LSP Support
                  (hover, completion, diagnostics)
```

## Progress

| Stage | Status | Notes |
|-------|--------|-------|
| 0. Associated Types — Declaration | ☐ todo | `type Elem` in typeclass definition |
| 1. Associated Type Resolution | ☐ todo | Projection `I::Item`, inference propagation |
| 2a. Indexed Protocol — Definition | ☐ todo | `Connected[Schema]` state parameters |
| 2b. Indexed Protocol — Checking | ☐ todo | Type parameter propagation through transitions |
| 3. Static Analysis Integration | ☐ todo | TypeChecker + EffectChecker + CallChecker |
| 4. LSP Support | ☐ todo | Hover, completion, diagnostics |

---

## Motivation

### Associated types: why

Type class parameters multiply when related types must be expressed:

```perl
# Current: E is redundant — determined by F
typeclass Container => 'F, E' => +{
    empty  => '() -> F',
    insert => '(E, F) -> F',
};

# With associated types: E is derived from F
typeclass Container => 'F' => +{
    type Elem,
    empty  => '() -> F',
    insert => '(Elem, F) -> F',
};

instance Container => 'Array[T]' => +{
    type Elem => 'T',
    empty  => sub { [] },
    insert => sub ($e, $xs) { [@$xs, $e] },
};
```

Associated types are type-level functions: given a type class instance, the associated type is uniquely determined. This avoids parameter explosion and makes the relationship explicit.

### Functional dependencies: why not (as surface syntax)

Functional dependencies (Jones 2000) express the same relationships as constraints:

```perl
# Fundep: "F determines E"
typeclass Container => 'F, E' => +{
    fundep => 'F -> E',
    ...
};
```

Schrijvers et al. (2008) showed associated types and fundeps are roughly equivalent in expressiveness. However:

- **Associated types** are explicit (type-level definitions, visible in `:sig()` as projections)
- **Functional dependencies** are implicit (constraints that guide inference non-locally)
- Typist's philosophy: "what is written is what is checked" — associated types fit better

**Internal use**: The resolution engine for associated types uses fundep-like reasoning internally. When an instance is selected, its associated types are determined — this is the fundep `F -> Elem` in practice. The surface syntax is associated types; the implementation uses functional dependency principles.

### Indexed protocol states: why

Current protocol states are opaque labels:

```perl
effect DB => qw/Connected Authed/ => +{
    connect => protocol('(Str) -> Handle', '* -> Connected'),
    ...
};
```

`Connected` carries no type information. Once connected, the handle's type (which schema? which permissions?) is lost. Indexed states attach type parameters to states:

```perl
effect TypedDB => qw/Connected[S]/ => +{
    connect => protocol('<S>(DSN[S]) -> Handle[S]', '* -> Connected[S]'),
    query   => protocol('<S>(Handle[S], Query[S]) -> Result[S]', 'Connected[S] -> Connected[S]'),
    close   => protocol('<S>() -> Void', 'Connected[S] -> *'),
};
```

Now `Connected[S]` propagates the schema type through the state machine. A function that connects with `DSN[UserDB]` enters state `Connected[UserDB]`, and subsequent operations are constrained to `UserDB` queries.

This connects to:
- **Indexed monads** (Atkey 2009): computations indexed by pre/post state
- **Graded monads** (Katsumata 2014): effects carrying algebraic structure
- **Session types** (Honda et al.): channels with typed state

### Convergence of associated types and indexed protocols

Associated types provide the mechanism for indexed protocols. A protocol state with parameters is an associated type of the effect:

```
typeclass-level:    instance Container => 'Array[T]' => +{ type Elem => 'T' }
protocol-level:     state Connected[S] in effect TypedDB
```

Both are type-level functions determined by context. Stage 0-1 (associated types) provides the infrastructure that Stage 2 (indexed protocols) builds upon.

---

## Stage 0: Associated Types — Declaration

**Goal**: `type Elem` declarations in type class definitions, `type Elem => 'T'` in instances.

### Syntax

```perl
typeclass Iterator => 'I' => +{
    type Item,                         # associated type declaration
    next => '(I) -> Option[Item]',     # Item used in op signatures
    has_next => '(I) -> Bool',
};

instance Iterator => 'ArrayIter[T]' => +{
    type Item => 'T',                  # associated type definition
    next     => sub ($iter) { ... },
    has_next => sub ($iter) { ... },
};

instance Iterator => 'HashIter[K, V]' => +{
    type Item => 'Tuple[K, V]',
    next     => sub ($iter) { ... },
    has_next => sub ($iter) { ... },
};
```

### Data model

```perl
# TypeClass::Def additions:
{
    associated_types => ['Item'],       # names of associated types
}

# Instance registration additions:
{
    associated_type_defs => {           # type name => type expression
        Item => 'T',                    # resolved relative to instance params
    },
}
```

### Parsing

In the ops hashref, entries with key `type` followed by a bareword are associated type declarations (in typeclass) or definitions (in instance):

```perl
# typeclass: type Item (no value — declaration)
# Detection: key eq 'type' is ambiguous with an op named 'type'.
# Resolution: use a distinct syntax marker.
```

**Syntax option A**: Reserved key prefix

```perl
typeclass Iterator => 'I' => +{
    type Item,                    # 'type' as keyword — conflicts with ops named 'type'
    next => '(I) -> Option[Item]',
};
```

**Syntax option B**: Separate section

```perl
typeclass Iterator => 'I' =>
    types => [qw/Item/],         # associated types declared separately
    ops   => +{
        next => '(I) -> Option[Item]',
    };
```

**Syntax option C**: Inline marker in ops hashref

```perl
typeclass Iterator => 'I' => +{
    'type:Item' => undef,         # declaration: undef value
    next        => '(I) -> Option[Item]',
};

instance Iterator => 'ArrayIter[T]' => +{
    'type:Item' => 'T',           # definition: type expression
    next        => sub ($iter) { ... },
};
```

**Recommendation**: Option A. `type` as a keyword inside the ops hashref. Perl's `+{}` constructor builds a plain hash, so `type Item` is `type => 'Item'` (fat comma auto-quotes). The parser detects `type => BAREWORD` as associated type declaration. In instance, `type Item => 'T'` is `type => 'Item', '=>', 'T'` — a 3-element flat list, parsed as `{ type => 'Item' }` with `'T'` as a dangling value.

This is problematic because Perl hashes lose ordering. **Revised option A**: Use a list-based syntax.

```perl
# Actually, +{} is a hash constructor. Can't rely on ordering.
# But: type Item, next => '...' in a hash is type => 'Item', next => '...'
# — which means 'type' key maps to 'Item', and 'next' maps to the sig.
# For instance: type Item => 'T', next => sub {...}
# — 'type' => 'Item', '=>' is problematic.
```

**Revised recommendation**: Option C. `type:Name` keys avoid ambiguity entirely.

```perl
typeclass Iterator => 'I' => +{
    'type:Item' => undef,                  # associated type declaration
    next        => '(I) -> Option[Item]',
};

instance Iterator => 'ArrayIter[T]' => +{
    'type:Item' => 'T',                    # associated type definition
    next        => sub ($iter) { ... },
};
```

Detection: keys matching `/^type:(\w+)$/` are associated types. Value `undef` = declaration, string value = definition.

### Tasks

- [ ] 0.1 `TypeClass::Def` — `associated_types` field, constructor support
- [ ] 0.2 `Typist.pm` `_typeclass` — detect `type:Name` keys, separate from ops, store in TypeClass::Def
- [ ] 0.3 `Typist.pm` `_instance` — detect `type:Name` keys, validate against typeclass, store definitions
- [ ] 0.4 `Registry` — `associated_type_defs`: `{ ClassName => { TypeName => { InstanceType => TypeExpr } } }`
- [ ] 0.5 `Extractor._extract_typeclasses` — PPI: detect `type:Name` keys in ops hashref
- [ ] 0.6 `Extractor._extract_instances` — PPI: detect `type:Name` keys
- [ ] 0.7 `Registration.register_typeclasses` — register associated type declarations
- [ ] 0.8 `Registration.register_instances` — register associated type definitions
- [ ] 0.9 `Checker` — validate instance provides all associated types, no extra types
- [ ] 0.10 Tests: `t/14_typeclass.t` — associated type declaration + definition

### Files

| File | Change |
|------|--------|
| `lib/Typist/TypeClass.pm` | `associated_types` field |
| `lib/Typist/Typist.pm` | `_typeclass`, `_instance`: `type:Name` key handling |
| `lib/Typist/Registry.pm` | `associated_type_defs` storage + lookup |
| `lib/Typist/Static/Extractor.pm` | Extract `type:Name` from PPI |
| `lib/Typist/Static/Registration.pm` | Register associated types |
| `lib/Typist/Static/Checker.pm` | Completeness check for associated types |
| `t/14_typeclass.t` | Tests |

---

## Stage 1: Associated Type Resolution

**Goal**: `I::Item` syntax in `:sig()` resolves to the concrete type via instance lookup.

### Projection syntax

```perl
# In :sig() annotations:
:sig('<I: Iterator>(I) -> Array[I::Item]')
sub collect($iter) { ... }

# In type expressions:
:sig('<F: Functor>(F[A]) -> F[Functor::Map[F, A]]')  # less common
```

The primary form is `TypeVar::AssocName` — a projection from a constrained type variable to its associated type.

### Resolution algorithm

```
resolve_projection(I::Item, bindings):
  1. I is bound to a concrete type T (e.g., ArrayIter[Int])
  2. Look up which instance of Iterator covers T → Iterator for ArrayIter[T']
  3. Unify T with ArrayIter[T'] → T' = Int
  4. Substitute into associated type def: Item = T' → Int
  5. Return Int
```

This is fundep-like reasoning: `I` determines `Item`.

### When resolution happens

- **Static path (TypeChecker)**: At call sites, after generic instantiation. `_maybe_instantiate_return` binds `I := ArrayIter[Int]`, then resolves `I::Item` → `Int` in the return type
- **Runtime path**: Not needed — associated types are erased. The concrete type is determined statically

### Type representation

New type node or existing mechanism:

```perl
# Option A: New Type::Projection node
Typist::Type::Projection->new(var => 'I', assoc => 'Item')
# to_string: 'I::Item'
# substitute: resolve via registry

# Option B: Encode as Type::Param with special base
Typist::Type::Param->new('I::Item', [])
# Already handled by Parser as qualified name
```

**Recommendation**: Option A. A dedicated `Type::Projection` node makes substitution and resolution explicit. It carries the type variable name and associated type name, and resolves during substitution/instantiation.

### Parser changes

`Parser.pm` must recognize `I::Item` as a projection:

```perl
# In parse():
# After parsing a token like 'I', check for '::' followed by uppercase word
# If the prefix matches a known generic param → Projection
# Otherwise → qualified type name (existing behavior)
```

Context-dependence: `I::Item` is a projection only when `I` is a type variable in scope. `Typist::Type::Atom` is a qualified name. The parser needs the generic parameter list to disambiguate.

### Tasks

- [ ] 1.1 `Type::Projection` — new type node: `var`, `assoc_name`, `to_string`, `substitute`, `free_vars`, `equals`
- [ ] 1.2 `Parser.parse` — recognize `Var::Name` pattern when generics context is available
- [ ] 1.3 `Parser.parse_annotation` — pass generic params to `parse` for projection recognition
- [ ] 1.4 `Type::Fold.map_type` — handle Projection nodes
- [ ] 1.5 `Registry.resolve_associated_type($class_name, $assoc_name, $instance_type)` — lookup + substitution
- [ ] 1.6 `Static::Infer` — resolve projections during generic instantiation
- [ ] 1.7 `Static::Unify` — projections unify after resolution
- [ ] 1.8 `Subtype` — projection subtyping after resolution
- [ ] 1.9 Tests: projection resolution in `:sig()`, cross-file, gradual (unknown instance → Any)

### Files

| File | Change |
|------|--------|
| `lib/Typist/Type/Projection.pm` | New: projection type node |
| `lib/Typist/Parser.pm` | Projection parsing with generic context |
| `lib/Typist/Type/Fold.pm` | `map_type` for Projection |
| `lib/Typist/Registry.pm` | `resolve_associated_type` |
| `lib/Typist/Static/Infer.pm` | Projection resolution |
| `lib/Typist/Static/Unify.pm` | Projection handling |
| `lib/Typist/Subtype.pm` | Projection subtyping |
| `t/14b_typeclass_assoc.t` | New: associated type tests |
| `t/static/` | Static analysis tests for projections |

### Gradual behavior

If the type variable's instance cannot be determined (gradual context), the projection resolves to `Any`. This is consistent with Typist's gradual typing principle: no information = no constraint.

### Example: Iterator with associated Item

```perl
use Typist;

typeclass Iterator => 'I' => +{
    'type:Item' => undef,
    next     => '(I) -> Option[Item]',
    has_next => '(I) -> Bool',
};

instance Iterator => 'ArrayIter[T]' => +{
    'type:Item' => 'T',
    next     => sub ($iter) { ... },
    has_next => sub ($iter) { ... },
};

# Item resolves to T when I = ArrayIter[T]
:sig('<I: Iterator>(I) -> Array[I::Item]')
sub collect($iter) {
    my @result;
    while (Iterator::has_next($iter)) {
        push @result, Iterator::next($iter);
    }
    \@result;
}

# At call site: collect(ArrayIter[Int]->new(...)) → Array[Int]
```

---

## Stage 2a: Indexed Protocol States — Definition & Extraction

**Goal**: Protocol states carry type parameters: `Connected[S]`, `Authenticated[U]`.

### Syntax

```perl
effect TypedDB => qw/Connected[S] Authed[S, U]/ => +{
    connect => protocol(
        '<S>(DSN[S]) -> Handle[S]',
        '* -> Connected[S]'
    ),
    auth => protocol(
        '<U>(Handle[S], Credentials[U]) -> Session[S, U]',
        'Connected[S] -> Authed[S, U]'
    ),
    query => protocol(
        '(Session[S, U], Query[S]) -> Result[S]',
        'Authed[S, U] -> Authed[S, U]'
    ),
    close => protocol(
        '() -> Void',
        'Connected[S] | Authed[S, U] -> *'
    ),
};
```

### State parameter semantics

State parameters in transitions are **bound by the operation's generics**. In the `connect` operation:
- Generic `<S>` is bound at the call site (e.g., `S = UserDB`)
- Transition `* -> Connected[S]` carries `S` into the state
- Subsequent operations in state `Connected[S]` inherit `S`

This creates a **type-level data flow through the state machine**:

```
* ──connect<UserDB>──→ Connected[UserDB] ──auth<Admin>──→ Authed[UserDB, Admin]
                                                               │
                                                          query (constrained to UserDB)
                                                               │
                                                          Authed[UserDB, Admin]
                                                               │
                                                          close → *
```

### Data model changes

```perl
# Protocol.pm additions:
{
    state_params => {
        'Connected' => ['S'],           # state name → param names
        'Authed'    => ['S', 'U'],
    },
    op_map => {
        connect => {
            from => ['*'],
            to   => ['Connected[S]'],   # parameterized state string
            generics => ['S'],          # operation-level generic binding
        },
        ...
    },
}

# Protocol state representation:
# A state is either:
#   - '*' (ground, no params)
#   - 'StateName' (unparameterized, backward compatible)
#   - 'StateName[T1, T2]' (indexed, new)
```

### State parsing

Extend `_make_protocol` and `Protocol.pm` to parse parameterized states:

```perl
# '* -> Connected[S]' → from => ['*'], to => ['Connected[S]']
# 'Connected[S] | Authed[S, U] -> *' → from => ['Connected[S]', 'Authed[S, U]'], to => ['*']

# State parameter extraction:
# 'Connected[S]' → { base => 'Connected', params => ['S'] }
# '*'            → { base => '*', params => [] }
```

### Extractor changes

`_extract_effects` must handle parameterized state names in `qw//`:

```perl
# qw/Connected[S] Authed[S, U]/ — PPI parses this as QuoteLike::Words
# Content: individual words may contain brackets
# Parse each word for parameterized form
```

**PPI caveat**: `qw/Connected[S]` is parsed as a single word `Connected[S]` by PPI (brackets inside `qw//` are literal). This is fortunate — no special PPI handling needed.

### Backward compatibility

Unparameterized states remain valid:

```perl
effect DB => qw/Connected Authed/ => +{ ... };  # unchanged
```

`state_params` is empty or absent for these. All existing protocol code continues to work.

### Tasks

- [ ] 2a.1 `Protocol.pm` — `state_params` field, parameterized state parsing
- [ ] 2a.2 `Protocol._parse_state` — extract `base` and `params` from state string
- [ ] 2a.3 `Typist.pm` `_make_protocol` — parse parameterized transitions
- [ ] 2a.4 `Typist.pm` `_effect` — parse parameterized state names from `qw//`
- [ ] 2a.5 `Extractor._extract_effects` — extract parameterized state names
- [ ] 2a.6 `Registration.register_effects` — pass state params to Protocol
- [ ] 2a.7 `Checker._check_protocols` — validate state param consistency across transitions
- [ ] 2a.8 Tests: `t/27d_protocol_indexed.t` — Protocol unit tests for indexed states

### Files

| File | Change |
|------|--------|
| `lib/Typist/Protocol.pm` | `state_params`, `_parse_state`, parameterized next_states |
| `lib/Typist/Typist.pm` | `_make_protocol`, `_effect`: parameterized states |
| `lib/Typist/Static/Extractor.pm` | Parameterized state extraction from `qw//` |
| `lib/Typist/Static/Registration.pm` | State params to Protocol |
| `lib/Typist/Static/Checker.pm` | State param consistency validation |
| `t/27d_protocol_indexed.t` | New: indexed protocol unit tests |

### Well-formedness rules

1. **State params must be bound**: Every parameter in a state must appear in some operation's generics that transitions to/from that state
2. **Consistency across transitions**: If `connect` produces `Connected[S]` and `auth` consumes `Connected[S]`, the `S` must refer to the same binding — enforced by name equality in the FSM trace
3. **Ground state has no params**: `*` never carries parameters
4. **Superposition**: `Connected[S] | Authed[S, U]` — parameters shared across alternatives must be compatible (same `S`)

---

## Stage 2b: Indexed Protocol — State-Indexed Checking

**Goal**: ProtocolChecker propagates type parameters through state transitions during function body tracing.

### Current checking model

```
trace_function(body, protocol, initial_states, final_states):
    current = initial_states          # e.g., ['*']
    for each op in body:
        current = protocol.next_states(current, op)
    check current == final_states
```

States are strings. `next_states` does set-based lookup.

### Indexed checking model

```
trace_function(body, protocol, initial_states, final_states, bindings):
    current = initial_states          # e.g., ['*']
    type_env = {}                     # state param bindings: { S => UserDB }
    for each op in body:
        # 1. Resolve op's generic args from call site
        op_bindings = resolve_call_generics(op)
        # 2. Verify current state params match op's from-state params
        check_state_params(current, op.from, type_env, op_bindings)
        # 3. Transition, substituting params in to-state
        current = protocol.next_states_indexed(current, op, op_bindings)
        # 4. Update type_env with new bindings
        merge(type_env, op_bindings)
    check current == final_states (modulo type_env substitution)
```

### Annotation syntax for indexed protocols

```perl
# Function annotations with indexed states:
sub connect_user :sig('<S>(DSN[S]) -> Handle[S] ![TypedDB<* -> Connected[S]>]') ($dsn) {
    TypedDB::connect($dsn);
}

sub full_session :sig('<S, U>(DSN[S], Credentials[U]) -> Result[S] ![TypedDB<* -> *>]') ($dsn, $cred) {
    TypedDB::connect($dsn);       # * → Connected[S]
    TypedDB::auth($cred);         # Connected[S] → Authed[S, U]
    my $r = TypedDB::query(...);  # Authed[S, U] → Authed[S, U]
    TypedDB::close();             # Authed[S, U] → *
    $r;
}
```

### Type safety through states

The key guarantee: **type parameters are preserved through transitions**.

```perl
sub unsafe :sig(() -> Void ![TypedDB<Connected[UserDB] -> Connected[AdminDB]>]') () {
    # ProtocolMismatch: no transition changes Connected's parameter
    # Operations preserve S — you can't "switch databases" mid-session
}
```

### Row label interaction

Row labels for indexed effects include state parameters:

```perl
# Row label: "TypedDB" (base)
# State annotation: <* -> Connected[S]>
# In Row: label = "TypedDB", label_states = { from => ['*'], to => ['Connected[S]'] }
```

State parameters in `label_states` are parsed by the existing Parser (they look like type expressions). The `S` in `Connected[S]` is a type variable from the function's generics.

### Tasks

- [ ] 2b.1 `ProtocolChecker` — `_trace_indexed`: state-indexed tracing with type_env
- [ ] 2b.2 `ProtocolChecker` — `_check_state_params`: verify from-state params match type_env
- [ ] 2b.3 `ProtocolChecker` — `_substitute_state_params`: substitute bindings in to-state
- [ ] 2b.4 `Protocol.next_states_indexed` — parameterized transition with bindings
- [ ] 2b.5 `Row.pm` — parse parameterized state expressions in `label_states`
- [ ] 2b.6 `Parser` — parse state params in `<Connected[S] -> Authed[S, U]>`
- [ ] 2b.7 Tests: `t/static/14b_protocol_indexed.t` — end-to-end indexed protocol checking

### Files

| File | Change |
|------|--------|
| `lib/Typist/Static/ProtocolChecker.pm` | `_trace_indexed`, state param checking |
| `lib/Typist/Protocol.pm` | `next_states_indexed` |
| `lib/Typist/Type/Row.pm` | Parameterized label_states parsing |
| `lib/Typist/Parser.pm` | State param expressions |
| `t/static/14b_protocol_indexed.t` | New: indexed protocol static tests |

### Example trace

```
Function: full_session<UserDB, Admin>
  Declared: ![TypedDB<* -> *>]

  Step 0: state = [*], type_env = {}
  Step 1: TypedDB::connect(dsn)     <S = UserDB>
          from: * (ok), to: Connected[S] → Connected[UserDB]
          state = [Connected[UserDB]], type_env = { S => UserDB }
  Step 2: TypedDB::auth(cred)       <U = Admin>
          from: Connected[S] → Connected[UserDB] (ok, S = UserDB matches)
          to: Authed[S, U] → Authed[UserDB, Admin]
          state = [Authed[UserDB, Admin]], type_env = { S => UserDB, U => Admin }
  Step 3: TypedDB::query(...)
          from: Authed[S, U] → Authed[UserDB, Admin] (ok)
          to: Authed[S, U] → Authed[UserDB, Admin]
          state = [Authed[UserDB, Admin]], type_env unchanged
  Step 4: TypedDB::close()
          from: Authed[S, U] → Authed[UserDB, Admin] (ok, superposition also allows Connected[S])
          to: *
          state = [*], type_env = { S => UserDB, U => Admin }

  Final: [*] == [*] ✓
```

---

## Stage 3: Static Analysis Integration

**Goal**: TypeChecker, EffectChecker, and CallChecker work with indexed protocols and associated types.

### TypeChecker: associated type resolution

When `_maybe_instantiate_return` binds generic `I := ArrayIter[Int]`:

1. Walk the return type for `Type::Projection` nodes
2. For each projection `I::Item`:
   a. Look up `I`'s constraint → `Iterator`
   b. Look up instance: `Iterator for ArrayIter[Int]`
   c. Resolve `Item` in that instance → `Int`
   d. Replace projection with `Atom('Int')`

### EffectChecker: indexed effect propagation

When checking `![TypedDB<* -> *>]`:

1. Parse state annotations for type parameters
2. During body scan, track state parameter bindings alongside state names
3. When a callee has indexed effect annotation (e.g., `![TypedDB<* -> Connected[S]>]`), propagate `S` binding from callee into caller's type_env
4. Final state check includes parameter consistency

### CallChecker: associated type in call args

```perl
:sig('<I: Iterator>(I, I::Item) -> I')
sub prepend($iter, $item) { ... }

# Call: prepend(ArrayIter[Int]->new(...), 42)
# CallChecker: I = ArrayIter[Int], I::Item = Int, check 42: Int ✓
```

### Tasks

- [ ] 3.1 `TypeChecker._resolve_projections` — walk type tree, resolve all Projection nodes
- [ ] 3.2 `TypeChecker._maybe_instantiate_return` — projection resolution after binding
- [ ] 3.3 `EffectChecker.check_function` — indexed state tracking delegation to ProtocolChecker
- [ ] 3.4 `CallChecker._check_call_arg_types` — resolve projections in expected param types
- [ ] 3.5 `TypeEnv._build_env` — projection-aware env construction
- [ ] 3.6 Tests: end-to-end static analysis with associated types + indexed protocols

### Files

| File | Change |
|------|--------|
| `lib/Typist/Static/TypeChecker.pm` | `_resolve_projections` |
| `lib/Typist/Static/EffectChecker.pm` | Indexed state propagation |
| `lib/Typist/Static/CallChecker.pm` | Projection resolution in call checks |
| `lib/Typist/Static/TypeEnv.pm` | Projection-aware env |
| `t/static/` | Integration tests |

---

## Stage 4: LSP Support

**Goal**: Hover, completion, and diagnostics for associated types and indexed protocols.

### Hover

```
# Hover on I::Item in :sig():
"Iterator::Item — associated type of Iterator
 Resolved to: Int (via Iterator for ArrayIter[Int])"

# Hover on TypedDB::connect:
"connect: <S>(DSN[S]) -> Handle[S]  [* → Connected[S]]"
```

### Completion

```
# After typing 'I::' where I: Iterator:
#   Item    (associated type)

# After typing '![TypedDB<Connected[' :
#   S       (state parameter from definition)
```

### Diagnostics

```
# New diagnostic kinds:
AssociatedTypeMissing    — instance lacks required associated type definition
AssociatedTypeExtra      — instance defines associated type not in typeclass
ProjectionUnresolvable   — cannot determine instance for projection
IndexedStateMismatch     — state parameter inconsistency in protocol trace
```

### Tasks

- [ ] 4.1 `Hover` — associated type display, indexed state display
- [ ] 4.2 `Completion` — associated type names, state parameter names
- [ ] 4.3 Diagnostics — new diagnostic kinds
- [ ] 4.4 `SemanticTokens` — Projection nodes as type references
- [ ] 4.5 Tests: LSP tests for associated types and indexed protocols

### Files

| File | Change |
|------|--------|
| `lib/Typist/LSP/Hover.pm` | Associated type + indexed state hover |
| `lib/Typist/LSP/Completion.pm` | Projection + state param completion |
| `lib/Typist/LSP/SemanticTokens.pm` | Projection token type |
| `t/lsp/` | LSP tests |

---

## Key Design Decisions

### 1. `type:Name` syntax for associated types

Using `type:Name` as hash keys avoids ambiguity with operation names. The `:` separator is visually distinct and parseable by both runtime (`_typeclass`/`_instance`) and static (Extractor PPI) paths.

### 2. `Type::Projection` as a dedicated node

Projections (`I::Item`) are not syntactic sugar — they are a new type-level construct that requires resolution during inference. A dedicated node makes this explicit in the type tree and allows `map_type`/`walk` to handle it uniformly.

### 3. State parameters are syntactically type expressions

`Connected[S]` reuses existing type expression syntax (`Name[Params]`). The Parser doesn't need new grammar rules — it's the same `parse()` that handles `Array[Int]`. The distinction between "state" and "type" is contextual (inside a protocol transition vs inside a `:sig()`).

### 4. Indexed checking extends, not replaces, current checking

The indexed checking model (`_trace_indexed`) is a superset of the current model. For unparameterized protocols, `type_env` is empty and `_trace_indexed` degenerates to the current `_trace` behavior. No backward-incompatible changes.

### 5. Gradual behavior for projections

If a projection `I::Item` cannot be resolved (no instance found, or `I` is `Any`), the projection resolves to `Any`. This is the standard gradual escape hatch. No hard error — the user simply loses type precision.

### 6. Runtime: indexed protocols are static-only

State parameters are a static-analysis concern. At runtime, protocol states remain strings (`"Connected"`, not `"Connected[UserDB]"`). The handler dispatch mechanism is unchanged. This aligns with Typist's static-first architecture.

---

## Dependency Order

```
Stage 0 ← (none)
Stage 1 ← Stage 0
Stage 2a ← (none, but shares concepts with Stage 0)
Stage 2b ← Stage 2a
Stage 3 ← Stage 1 + Stage 2b
Stage 4 ← Stage 3

Stage 0 and Stage 2a are independent of each other.
Stage 1 and Stage 2b can proceed in parallel after their prerequisites.
```

---

## Interaction with Existing Features

### Per-effect generics (`State[S]`)

Indexed protocols extend per-effect generics. Currently `State[S]` parameterizes the effect itself. Indexed states parameterize individual states within a protocol. These compose:

```perl
# Effect-level generic + state-level generic:
effect 'TypedStore[K]' => qw/Open[S]/ => +{
    open  => protocol('<S>(Schema[S]) -> Void', '* -> Open[S]'),
    get   => protocol('(K) -> Option[S]',       'Open[S] -> Open[S]'),
    close => protocol('() -> Void',             'Open[S] -> *'),
};
# K: effect-level (same across all operations)
# S: state-level (bound at open, flows through states)
```

### Scoped effects

Scoped effects with indexed protocols: `scoped 'TypedDB[UserDB]'` creates a scope where the effect is pre-parameterized at the effect level. State-level parameters are still dynamic (bound by operations). No conflict.

### Bounded quantification

State parameters can have bounds:

```perl
# Future extension (not in initial implementation):
effect TypedDB => qw/Connected[S: Schema]/ => +{ ... };
```

This requires `parse_generic_decl`-style parsing for state parameter declarations. Deferred to avoid scope creep.

### HKT generics

HKT parameters on effects (`Collect[F: * -> *]`) are orthogonal to indexed protocol states. An effect can have both:

```perl
# Hypothetical (very advanced):
effect 'Transform[F: * -> *]' => qw/Loaded[S]/ => +{
    load => protocol('<S>(Source[S]) -> F[S]', '* -> Loaded[S]'),
    ...
};
```

This is a combination of HKT (Stage from hkt-generics-plan) and indexed protocols (this plan). Deferred but architecturally compatible.

---

## Open Questions

1. **Multiple associated types with dependencies**: Can one associated type reference another? E.g., `type Key` and `type Value` where `Value` depends on `Key`. This introduces ordering within associated type declarations. Deferred.

2. **Associated type defaults**: Should `type:Item => 'Any'` in the typeclass (not instance) provide a default? Haskell supports this. Low priority.

3. **State parameter inference from context**: When a function calls `TypedDB::connect($dsn)` without explicit generic annotation, can `S` be inferred from `$dsn`'s type? This depends on TypeChecker's generic instantiation for effect operations. Should work via existing `_maybe_instantiate_return` if effect ops are registered as generic functions.

4. **Existential state parameters**: Can a function declare `![TypedDB<Connected[_]>]` to say "connected to some unknown schema"? The `_` wildcard would act as an existential. Interesting but deferred.

5. **State parameter variance**: Is `Connected[UserDB]` a subtype of `Connected[Any]`? Following the Protocol FSM invariance principle (states are exact), the answer is no. State parameters are invariant.

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| `type:Name` syntax confusing to users | Medium | Clear documentation, familiar from Rust/Haskell |
| Projection resolution performance | Low | Cached via registry; projection count per function is small |
| Indexed state explosion (too many params) | Low | Practical protocols have 1-2 state params |
| PPI extraction of `type:Name` keys | Medium | Test against PPI Quote::Single for `'type:Item'` |
| Backward compat for Protocol.pm | Low | Unparameterized states degenerate cleanly |
| Complexity in ProtocolChecker | High | Thorough trace-level tests; indexed trace extends current trace |
| Parser ambiguity for `I::Item` vs `Package::Name` | Medium | Context (generic params) disambiguates; fallback to qualified name |
