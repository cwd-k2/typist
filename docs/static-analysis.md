# Typist Static Analysis Internals

This document describes the internal workings of Typist's static analysis pipeline: how type and effect errors are detected at compile time.

> **Related documentation**: [architecture.md](architecture.md) (system overview) | [type-system.md](type-system.md) (type theory) | [conventions.md](conventions.md) (coding conventions) | [lsp-coverage.md](lsp-coverage.md) (LSP features)

## Table of Contents

- [Pipeline Overview](#pipeline-overview)
- [Extractor: PPI-Based Annotation Extraction](#extractor-ppi-based-annotation-extraction)
- [Checker: Structural Validation](#checker-structural-validation)
- [TypeChecker: Type Mismatch Detection](#typechecker-type-mismatch-detection)
- [Arity Checking](#arity-checking)
- [Variable Reassignment Tracking](#variable-reassignment-tracking)
- [Generic Static Type Checking](#generic-static-type-checking)
- [Method Type Checking](#method-type-checking)
- [Type Narrowing](#type-narrowing)
- [Branch Return Analysis](#branch-return-analysis)
- [Builtin Prelude](#builtin-prelude)
- [EffectChecker: Effect Mismatch Detection](#effectchecker-effect-mismatch-detection)
- [Infer: Static Type Inference](#infer-static-type-inference)
- [Gradual Typing Semantics](#gradual-typing-semantics)
- [Cross-File Support](#cross-file-support)
- [Diagnostic Infrastructure](#diagnostic-infrastructure)
- [Suppression Mechanisms](#suppression-mechanisms)
- [Known Limitations](#known-limitations)

---

## Pipeline Overview

The static analysis pipeline processes one source file at a time, coordinated by `Static::Analyzer`:

```
                    Source Code (string)
                         |
                         v
              +---------------------+
              |  Analyzer.analyze() |
              +---------------------+
                         |
          +--------------+--------------+
          |              |              |
          v              v              v
   +-----------+  +------------+  +-----------+
   | Extractor |  | Merge WS   |  | Register  |
   | (PPI)     |  | Registry   |  | extracted |
   +-----------+  +------------+  +-----------+
          |              |              |
          |              v              v
          |        Prelude.install  local Registry
          |              |              |
          +--------+-----+------+------+
                   |       |       |
                   v       v       v
            +--------+ +--------+ +--------+
            |Checker | |TypeChk | |EffChk  |
            +--------+ +--------+ +--------+
                   |       |       |
                   v       v       v
              +------------------------+
              |  Diagnostics (merged)  |
              +------------------------+
```

### Entry Points

The analyzer is invoked from two contexts:

| Context | Caller | Registry Mode |
|---------|--------|---------------|
| CHECK phase | `Typist::_check_analyze()` | Singleton (class methods) |
| LSP | `LSP::Document->analyze()` | Instance (per-workspace) |

Both use the same `Analyzer->analyze($source, %opts)` interface.

---

## Extractor: PPI-Based Annotation Extraction

`Static::Extractor` parses Perl source into a PPI AST and extracts all Typist-relevant declarations.

### Extraction Targets

```
Extractor->extract($source)
  |
  +-> { package }        Package name (first PPI::Statement::Package)
  +-> { aliases }        { Name => { expr, line, col } }
  +-> { newtypes }       { Name => { inner_expr, line, col } }
  +-> { datatypes }      { Name => { variants, line, col } }
  +-> { effects }        { Name => { line, col } }
  +-> { typeclasses }    { Name => { var_spec, method_names, line, col } }
  +-> { declares }       { Name => { pkg, func_name, type_expr, line, col } }
  +-> { variables }      [ { name, type_expr, init_node, line, col }, ... ]
  +-> { functions }      { name => { params_expr, returns_expr, generics,
  |                                   eff_expr, param_names, is_method,
  |                                   method_kind, line, end_line,
  |                                   col, block, unannotated } }
  +-> { ignore_lines }   { line_number => 1 }   (from @typist-ignore)
  +-> { ppi_doc }        PPI::Document object
```

### Pattern Recognition

Each extraction target has a specific PPI pattern:

```
typedef:    Statement[ Word("typedef"), Word(Name), Operator("=>"), ... ]
newtype:    Statement[ Word("newtype"), Word(Name), Operator("=>"), ... ]
datatype:   Statement[ Word("datatype"), Word(Name), Operator("=>"),
                       Word(Tag), Operator("=>"), Quote(spec), ... ]
effect:     Statement[ Word("effect"), Word(Name), Operator("=>"), ... ]
typeclass:  Statement[ Word("typeclass"), Word(Name), Operator("=>"), ... ]
declare:    Statement[ Word("declare"), Word(Name), Operator("=>"), Quote(expr) ]

Variable:   Statement::Variable[ Symbol($x), Operator(:), Word(Type), List(...) ]
            PPI doesn't parse variable attributes as PPI::Token::Attribute,
            so the :sig(...) pattern is reconstructed manually.

Function:   Statement::Sub[ Word(name), Token::Attribute("Type(...)"), Block ]
            Regex match: /\AType\((.+)\)\z/s on attribute content

Method:     Function where first param_name is $self (instance) or $class (class)
            Registered via register_method instead of register_function
```

### Unannotated Function Handling

Functions without `:sig()` are still extracted with:

```perl
{
    params_expr => [('Any') x $arity],   # All params are Any
    returns_expr => 'Any',
    unannotated => 1,
}
```

This enables the effect checker to flag unannotated callees. For methods, `$self`/`$class` is excluded from the arity count.

---

## Checker: Structural Validation

`Static::Checker` operates on the Registry contents (not PPI), validating structural well-formedness.

### Checks Performed

```
Checker->analyze()
  |
  +-> _check_aliases()
  |     For each alias in Registry:
  |       eval { registry->lookup_type(name) }
  |       If throws "cycle": collect CycleError
  |
  +-> _check_functions()
  |     For each registered function:
  |       +-> Collect free_vars from all param/return types
  |       +-> Deduplicate via %seen_free
  |       +-> For each free var not in generics: UndeclaredTypeVar
  |       +-> Validate effects via _check_effect_wellformed()
  |       |     For each effect label: must be registered
  |       |     For each row variable: must be in generics
  |       +-> Validate bound expressions (parse test)
  |       +-> Walk param/return types via Fold->walk()
  |       |     For each Alias node: must be defined
  |       +-> KindChecker->infer_kind() for kind errors
  |
  +-> _check_typeclasses()
        For each typeclass:
          Verify superclasses exist
          DFS cycle detection on inheritance graph
```

### Type Tree Walking

The Checker uses `Type::Fold->walk($type, $cb)` for top-down traversal:

```
walk(Param(ArrayRef, [Atom(Int)]))
  cb(Param)
  cb(Atom(Int))

walk(Func([Atom(Str)], Atom(Int), Eff(Row(Console))))
  cb(Func)
  cb(Atom(Str))
  cb(Atom(Int))
  cb(Eff)
  cb(Row(Console))
```

---

## TypeChecker: Type Mismatch Detection

`Static::TypeChecker` uses PPI AST nodes to detect type mismatches across five categories: variable initializers, assignments, call sites (including generics and methods), and return types.

### Type Environment Construction

Before checking, the TypeChecker builds an environment `$env`:

```
_build_env()
  |
  +-> env.variables:  { "$x" => Type }       From :Type annotations + inference
  +-> env.functions:  { "add" => ReturnType } From :Type annotations
  +-> env.known:      { "add" => 1 }          Names with any annotation
  +-> env.registry:   Registry                For cross-package lookups
```

The build is two-phased:

```
Phase 1: Load explicitly annotated variables and function return types
Phase 2: For unannotated variables with initializers:
           inferred_type = Infer->infer_expr(init_node, partial_env)
           env.variables{$var} = inferred_type
```

This enables flow typing: `my $x = add(1, 2)` infers `$x: Int` from `add`'s return type.

### Check 1: Variable Initializers

```
For each variable with type_expr AND init_node:
  inferred = Infer->infer_expr(init_node, env)
  declared = Parser->parse(type_expr)

  Skip if:
    - inferred is undef (cannot infer)
    - inferred is Any (gradual)
    - declared has free type variables

  if !Subtype->is_subtype(inferred, declared):
    collect TypeMismatch
```

### Check 2: Call Sites

```
For each PPI::Token::Word in document:
  If preceded by -> operator:
    → delegate to _check_method_call (see Method Type Checking)
    → next

  Resolve function signature:
    1. Local: extracted.functions{name}
    2. Cross-package: split "Pkg::func", registry->lookup_function(pkg, func)
    3. Builtin: registry->lookup_function('CORE', name)  (from Prelude or declare)

  Skip if: sub declaration name, no following List

  Arity check (see Arity Checking)

  If generic function:
    → delegate to _check_generic_call (see Generic Static Type Checking)
    → next

  Build scoped env:
    env = _env_for_node(word)
    If inside a function body: add parameter bindings to env

  For each argument (up to min(params, args)):
    inferred = Infer->infer_expr(arg, env)
    declared = param_types[i]
    if !Subtype->is_subtype(inferred, declared):
      collect TypeMismatch
```

### Check 3: Return Types

```
For each function with returns_expr AND block:
  declared_return = Parser->parse(returns_expr)

  Explicit returns:
    Find all 'return' keywords in block
    For each: infer the returned expression, check against declared

  Implicit return (see Branch Return Analysis):
    Skip if declared return is Void
    Get last statement of block
    Recursively walk branches via _check_implicit_return_of_stmt
```

### Scoped Environment

`_env_for_node($node)` walks up the PPI parent chain to find the enclosing function. If found, it creates a scoped environment with parameter bindings added. It then applies type narrowing (see Type Narrowing).

```
Global env:  { variables: { $x => Int }, functions: { add => Int } }
                            +
Inside add:  { variables: { $x => Int, $a => Int, $b => Int }, ... }
```

---

## Arity Checking

The TypeChecker verifies that the number of arguments at each call site matches the function's declared parameter count. This applies to both regular function calls and method calls.

### Algorithm

```
For each call site (function or method):
  param_count = number of declared parameters
  arg_count   = number of extracted arguments

  If last parameter type matches /ArrayRef/:
    → variadic function, skip arity check

  If arg_count != param_count:
    collect ArityMismatch
      "name() expects N arguments, got M"
```

### Argument Extraction

`_extract_args()` groups compound expressions as single arguments:

- `Word + List` pairs are grouped as one argument (function call: `greet("hi")`)
- `Token -> Subscript` chains are consumed as trailing dereference (e.g., `$item->{key}`)
- Commas separate arguments

This prevents `add(greet("hi"), 42)` from being counted as 3 arguments.

---

## Variable Reassignment Tracking

The TypeChecker detects type mismatches in variable reassignment after initialization. Only **explicitly annotated** variables are checked; unannotated variables (inferred types) are not tracked.

### Algorithm

```
_check_assignments():
  annotated = { name => 1 } for variables with type_expr

  For each '=' operator in document:
    LHS must be a Symbol (variable name)
    Skip unless annotated{var_name}
    Skip if inside a variable declaration (handled by initializer check)

    declared_type = env.variables{var_name}
    inferred = Infer->infer_expr(RHS, env)

    if !Subtype->is_subtype(inferred, declared_type):
      collect TypeMismatch
        "Assignment to $var: expected T, got U"
```

The annotated-only guard prevents false positives on variables whose types were inferred and may legitimately change.

---

## Generic Static Type Checking

Generic function calls are type-checked via structural unification, implemented in `Static::Unify`.

### Unification Algorithm

`Unify->unify($formal, $actual, $bindings)` performs structural matching:

```
Var('T')   vs  Atom('Int')                → { T => Int }
Param('ArrayRef', [Var('T')])
    vs  Param('ArrayRef', [Atom('Int')])  → { T => Int }
Atom('Int') vs  Atom('Str')              → undef (mismatch)
Atom('Int') vs  Atom('Int')              → {} (match, no bindings)
```

When a type variable is already bound, the binding is widened via `common_super`:

```
T already bound to Int, now unifying with Num → T := Num  (LUB)
```

### Full Pipeline

```
_check_generic_call(name, fn, args, env, word):
  1. Infer argument types (skip if any arg is Any or non-inferable)
  2. Parse generic declarations to extract var names, bounds, and tc_constraints
  3. Resolve formal parameter types, converting aliases to type variables
  4. Unify: pair formal params with actual args to bind type variables
     If unification fails → TypeMismatch at failing parameter
  5. Bounded quantification check:
     For each generic with bound_expr:
       actual = bindings{name}
       if !Subtype->is_subtype(actual, bound):
         → TypeMismatch: "T does not satisfy bound Num"
  5.5. Typeclass constraint check:
       For each generic with tc_constraints:
         actual = bindings{name}
         for each tc_name in tc_constraints:
           if !Registry->resolve_instance(tc_name, actual):
             → TypeMismatch: "no instance of Show for Str"
  6. Concrete subtype check:
     Substitute bindings into formal types, verify each arg
```

### Generic Struct Constructor Check

Struct constructors with type parameters use a two-pass approach in `_check_struct_constructor_call`:

```
Pass 1: Collect bindings
  For each field => value pair:
    - Infer value type
    - collect_bindings(formal_field_type, inferred) into %bindings

Pass 2: Verify with substituted types
  For each field:
    - Substitute bindings into formal field type
    - Check is_subtype(inferred, substituted_expected)
```

The inference side (`_instantiate_generic_struct` in `Static::Infer`) follows the same two-pass binding pattern but also widens literal types (`Literal(42, Int)` → `Atom(Int)`) before producing type_args.

### Alias-to-Var Conversion

Generic functions use multi-character type variable names (e.g., `Elem`). Since the parser treats unknown names as aliases, `Transform->aliases_to_vars()` converts alias references back to `Var` nodes based on the known generic variable names before unification.

---

## Method Type Checking

The TypeChecker supports method call-site checking for `$self` and struct-typed receivers.

### Scope

- **Supported**: `$self->method()` (same-package instance methods)
- **Supported**: `$var->method()` where `$var` has a struct type inferred from env (cross-package via struct name resolution)
- **Not supported**: class method calls (`Class->method()`), chained calls (`$p->with(...)->method()`), non-struct receiver types, generic methods

### Algorithm

```
_check_method_call(word, arrow):
  Receiver must be PPI::Token::Symbol

  Path A ($self):
    pkg = extracted.package (same-package)

  Path B (other variable):
    recv_type = env.variables[receiver]
    Chase aliases via registry
    If recv_type.is_struct → pkg = recv_type.name
    Else → gradual skip (return)

  Lookup: registry->lookup_method(pkg, name)
  Fallback: registry->lookup_method(recv_type.package, name)  # struct accessors
  Skip if method has generics

  Arity check on arguments (excluding $self)
  Type check each argument against declared param types
```

### Registration Flow

Methods are distinguished from functions during extraction:

```
Extractor: first param $self → is_method=1, method_kind='instance'
           first param $class → is_method=1, method_kind='class'
Analyzer:  if is_method → registry->register_method(pkg, name, sig)
           else         → registry->register_function(pkg, name, sig)
```

---

## Type Narrowing

The TypeChecker narrows types within control-flow guard blocks and after early returns.

### Narrowing Rules

Five narrowing rules are supported, dispatched in order of specificity:

```
Rule           Condition                 Result in then-block        Result in else-block
─────────────  ────────────────────────  ────────────────────────    ────────────────────
defined()      `defined($x)`            Remove Undef from union     Undef only
isa            `$x isa Type`            Narrow to Type              (no inverse)
ref()          `ref($x) eq 'TYPE'`      Narrow to ref type          (no inverse)
truthiness     `if ($x)`                Remove Undef from union     (no inverse)
early return   `return unless defined`  Narrow remainder of body    N/A
```

The `ref()` rule maps string literals to types: `HASH` → `HashRef[Any]`, `ARRAY` → `ArrayRef[Any]`, `SCALAR` → `Ref[Any]`, `CODE` → `Ref[Any]`. Blessed class names are resolved via registry. Only the `eq` operator with a literal string is recognized; `ne`, negated conditions, and variable comparisons are not supported.

The `unless` keyword reverses polarity: in `unless (defined($x))`, the then-block sees the inverse narrowing.

### Algorithm

```
_narrow_env_for_block(env, node):
  Walk up to nearest enclosing Block
  Parent must be a Compound statement (if/elsif/unless/while)
  Detect then-block vs else-block position

  Dispatch rules (most specific first):
    1. _narrow_defined    → defined($x) or defined $x
    2. _narrow_isa        → $x isa Type
    3. _narrow_ref        → ref($x) eq 'TYPE'
    4. _narrow_truthiness → bare $x

  Apply narrowing or inverse based on block polarity

_scan_early_returns(env, node):
  Walk preceding siblings in the enclosing block
  Match: `return unless defined($x)` pattern
  Narrow env for the remainder of the body
```

### Examples

```perl
my $x :sig(Str | Undef) = get_value();
if (defined($x)) {
    # $x is narrowed to Str here
    process($x);   # No TypeMismatch even though declared as Str | Undef
}

if ($x) {
    # $x is narrowed to Str (Undef removed by truthiness)
}

if ($x isa Person) {
    # $x is narrowed to Person
}

if (ref($data) eq 'HASH') {
    # $data is narrowed to HashRef[Any]
}

return unless defined($x);
# After this point, $x is narrowed to Str for the rest of the body
```

---

## Branch Return Analysis

Implicit return type checking recursively walks into compound statements (if/elsif/else, while, for) to check the last expression of each branch.

### Algorithm

```
_check_implicit_return_of_stmt(stmt, env, declared, name):
  Skip nested sub definitions

  If stmt is Compound (if/elsif/else/while/for):
    For each Block child:
      Get last statement in block
      Recurse: _check_implicit_return_of_stmt(last_stmt, ...)

  Base case (plain statement):
    Skip if starts with 'return' (already checked)
    Skip if declared return is Void
    Infer type of first expression
    Check against declared return type
```

This ensures that all branches of a conditional contribute to the return type check, not just the last top-level statement.

---

## Builtin Prelude

`Typist::Prelude` provides standard type annotations for Perl builtins, installed into the registry under the `CORE::` namespace.

### Installation

The prelude is installed during `Analyzer->analyze()` and `Workspace->new()` via `Prelude->install($registry)`.

### Override Semantics

User `declare` statements override prelude entries. Since `register_function` uses plain assignment, a subsequent `declare say => '(Str) -> Bool ![Console]'` replaces the prelude's default.

### Standard Annotations

```
IO effects:     say, print, warn              → ![IO]
                open, close, read, write      → ![IO]
                rand, srand, sleep, time      → ![IO]
                localtime, gmtime             → ![IO]
                require, use                  → ![IO]
                system, exec                  → ![IO]
Exn effects:    die                           → ![Exn]
                eval, exit                    → ![Exn]
Decl effects:   typedef, newtype, effect      → ![Decl]
                typeclass, instance, declare  → ![Decl]
                datatype, enum, struct        → ![Decl]

Pure string:    length, substr, uc, lc, index → pure
Pure numeric:   abs, int, sqrt                → pure
Pure list:      scalar, reverse, sort         → pure
```

### Standard Effect Labels

The prelude registers three standard effect labels — `IO`, `Exn`, and `Decl` — so the Checker does not report them as `UnknownEffect`.

---

## EffectChecker: Effect Mismatch Detection

`Static::EffectChecker` verifies that effect annotations are consistent across the call graph.

### Algorithm

```
For each annotated function (skip unannotated entirely):
  caller_eff = registry.lookup(pkg, name).effects

  Collect all function calls in the body:
    For each PPI::Token::Word:
      Skip: keywords, sub declaration names, method calls (->), hash keys (=>)

      If builtin (say, print, die, open, ...):
        Check CORE registry for declare'd annotation:
          - Declared with effects → use those
          - Declared pure or not declared → skip (pure)

      If local/cross-package function with argument list:
        Lookup in registry → { effects }
        Unannotated functions (row_var '*') → skip (pure)

  For each callee:
    If caller has no effects (pure) but callee does:
      → EffectMismatch: "caller has no :Eff but calls effectful callee"

    If both have closed rows:
      Check label inclusion: callee labels ⊆ caller labels
      If not subset:
        → EffectMismatch: "missing effects: [labels]"

    If either has an open row (row variable):
      → Skip (requires runtime unification)
```

### Builtin Function Set

The EffectChecker maintains a hardcoded set of ~50 Perl builtins that it recognizes as potential call sites (say, print, warn, die, open, close, read, write, etc.). These are treated as pure (no effects) unless the Prelude or a `declare` provides an annotation.

### Effect Inference (LSP Hints)

`infer_effects($extracted, $registry)` computes likely effect labels for unannotated functions by collecting effects from annotated callees in the function body. Results are surfaced as LSP inlay hints only.

```
For each unannotated function:
  Collect callee effects via _collect_called_effects
  Union all closed-row labels from annotated callees
  (Unannotated callees are pure → skipped)

  Result: { name, labels => [...], unknown, line, col }
```

Inlay hints render as `![IO, Exn]` (known labels) or `![IO, ...]` (some labels known, others unknown) after the function name.

Inference is shallow: only direct callees in the function body are examined. Effects from method calls, closures, callbacks, and transitive calls through other unannotated functions are not traced.

---

## Infer: Static Type Inference

`Static::Infer` infers types from PPI elements. It is the foundation of all TypeChecker checks.

### Public API

```perl
my $type = Typist::Static::Infer->infer_expr($ppi_element, $env);
# Returns: Type object, or undef (cannot infer)
```

### Expression Inference Capabilities

```
PPI Element                    Result                    Notes
─────────────────────────────  ────────────────────────  ─────────────
PPI::Token::Number::Float      Literal(val, 'Double')
PPI::Token::Number::Exp        Literal(val, 'Double')
PPI::Token::Number (0 or 1)    Literal(val, 'Bool')
PPI::Token::Number (other)     Literal(val, 'Int')
PPI::Token::Quote              Literal(string, 'Str')   Uses ->string
PPI::Token::Quote::Double      Atom('Str')              Interpolated ("$x")
PPI::Token::Quote::Interpolate Atom('Str')              Interpolated (qq{})
PPI::Token::HereDoc            Atom('Str')
PPI::Token::Word 'undef'       Atom('Undef')
PPI::Structure::Constructor[]  Param('ArrayRef', LUB)   _infer_array
PPI::Structure::Constructor{}  Param('HashRef',S,LUB)   _infer_hash (needs =>)
PPI::Token::Symbol             env.variables{content}   Needs $env
PPI::Token::Symbol + ->[idx]   ArrayRef[T] → T          Subscript access
PPI::Token::Symbol + ->{key}   HashRef[K,V] → V         Subscript access
PPI::Token::Symbol + ->{key}   Struct field → type      Struct field access
PPI::Token::Word + List        env.functions{name}      _infer_call
PPI::Token::Word + List        CORE builtin returns     Prelude/declare fallback

Operator Expressions:
$a + $b, $a - $b, ...         Atom('Num')              Arithmetic
$a . $b                       Atom('Str')              Concatenation
$a == $b, $a < $b, ...        Atom('Bool')             Numeric comparison
$a eq $b, $a lt $b, ...       Atom('Bool')             String comparison
$a =~ /pat/, $a !~ /pat/      Atom('Bool')             Regex match
!$x, not $x                   Atom('Bool')             Unary negation
$a && $b, $a || $b, ...       type of LHS              Logical operators
$x ? $a : $b                  LUB or Union             Ternary (see below)
```

### Ternary Inference

When inferring `$x ? $a : $b`:

1. Infer both branch types, widen literals to base atoms
2. If same type after widening, return that type
3. Compute LUB via `common_super`; if LUB is `Any`, use `Union` instead

### Subscript Access Inference

When inferring `$sym->[idx]` or `$sym->{key}`:

```
ArrayRef[T] → T               Array element access
HashRef[K, V] → V             Hash value access
Struct{ k => T } → T          Struct field access (bare word or quoted key)
```

### LUB (Least Upper Bound) for Arrays

When inferring `[1, "a", 3.14]`, the inferrer:

1. Infers each element: `Literal(1, Int)`, `Literal("a", Str)`, `Literal(3.14, Double)`
2. Promotes literals to atoms: `Int`, `Str`, `Double`
3. Computes LUB pairwise: `common_super(Int, Str)` = `Any`, etc.
4. Returns `ArrayRef[Any]`

---

## Gradual Typing Semantics

Typist implements gradual typing where annotation density determines check strictness:

### Four Annotation Levels

```
Level                    Example                               Behavior
─────────────────────    ───────────────────────────            ──────────────────────
Fully annotated          :sig((Str) -> Int ![Console])        All checks active
Partial (no return)      :sig((Str) -> Any)                   Params checked, return unknown
Partial (no effect)      :sig((Str) -> Int)                   Types checked, treated as pure
Unannotated              sub foo ($x) { ... }                  Skipped (Any -> Any, pure)
```

### Implementation: The Any Guard

Every check method has an `Any` guard that prevents false positives:

```perl
# In _check_variable_initializers, _check_assignments, _check_call_sites,
# _check_return_types, _check_method_call, _check_generic_call:
next if $inferred->is_atom && $inferred->name eq 'Any';
```

### Implementation: known vs. functions Maps

```
env.functions{name}:  Has an entry → return type is known → use it
env.known{name}:      Has an entry, not in functions → partial annotation
                      Return type is undef → skip type check (no false positive)
Neither:              Completely unannotated → return Any → gradual bypass
```

### Unannotated in EffectChecker

```
Unannotated function as CALLER:  Skipped entirely (line 47)
Unannotated function as CALLEE:  Flagged with EffectMismatch (may perform any effect)
```

---

## Cross-File Support

### CHECK Phase

The CHECK block in `Typist.pm` passes the global singleton Registry as `workspace_registry`. Since all `use Typist` packages call `import` at compile time, the singleton already contains all registered functions and types from other packages when the CHECK block runs.

```
Package A (compiled first):
  import() → register_function('A', 'foo', ...)

Package B (compiled second):
  import() → register_function('B', 'bar', ...)

CHECK phase:
  Analyzer->analyze(B_source, workspace_registry => singleton)
    → Registry has A::foo → can type-check B's calls to A::foo
```

### LSP Workspace

`LSP::Workspace` provides cross-file support for the LSP:

```
Workspace.scan(root)
  |
  +-> Find all *.pm files under root
  +-> Install Prelude into registry
  +-> For each file:
        Extractor->extract(source)
        _register_file_types(extracted)
          +-> aliases, newtypes, datatypes, effects,
          +-> typeclasses, declares, functions, methods
  +-> Store all extracted data for rebuild

Workspace.update_file(uri, source)  [on save]
  +-> Delete stale file entry
  +-> _rebuild_registry()           # Re-register from all stored data
  +-> Process new source
```

### Cross-Package Call Resolution

In both TypeChecker and EffectChecker, `Pkg::func()` calls are resolved:

```perl
# TypeChecker._check_call_sites:
if ($name =~ /\A(.+)::(\w+)\z/) {
    my ($pkg, $fn) = ($1, $2);
    $sig = $self->{registry}->lookup_function($pkg, $fn);
}
```

---

## Diagnostic Infrastructure

### Diagnostic Structure

```perl
{
    kind     => 'TypeMismatch',           # Diagnostic kind
    message  => 'Expected Int, got Str',  # Human-readable
    file     => 'lib/Foo.pm',             # Source file
    severity => 2,                        # 1=critical, 2=error, 3=warning, 4=info
}
```

### Severity Mapping

```
1 (Critical)  CycleError
2 (Error)     TypeMismatch, ArityMismatch, TypeError, ResolveError,
              UnknownTypeClass, EffectMismatch
3 (Warning)   UndeclaredTypeVar, UndeclaredRowVar, UnknownEffect
4 (Info)      UnknownType
```

### Enrichment

Raw errors from checkers may lack precise file/line information. `Analyzer._to_diagnostics()` enriches them by:

1. Matching error messages against extracted symbol names
2. Looking up the symbol's line/column from the extracted data
3. Filtering out lines marked with `@typist-ignore`

---

## Suppression Mechanisms

### @typist-ignore Comment

A comment `# @typist-ignore` on line N suppresses all diagnostics on line N+1:

```perl
sub handler :sig((Str) -> Str ![Console]) ($s) {
    # @typist-ignore
    some_unannotated_function($s);  # No EffectMismatch
}
```

### TYPIST_CHECK_QUIET

Setting `TYPIST_CHECK_QUIET=1` skips the entire `_check_analyze()` pass in the CHECK block. Use this when `typist-lsp` provides diagnostics to avoid duplicate output.

---

## Known Limitations

### Expression Inference

| Limitation | Impact |
|------------|--------|
| Operator precedence | Does not influence inferred types |

### Effects

| Limitation | Impact |
|------------|--------|
| Effect inference is shallow | Only direct callees examined; method calls, closures, callbacks, transitive unannotated chains not traced |
