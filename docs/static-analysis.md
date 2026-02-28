# Typist Static Analysis Internals

This document describes the internal workings of Typist's static analysis pipeline: how type and effect errors are detected at compile time.

## Table of Contents

- [Pipeline Overview](#pipeline-overview)
- [Extractor: PPI-Based Annotation Extraction](#extractor-ppi-based-annotation-extraction)
- [Checker: Structural Validation](#checker-structural-validation)
- [TypeChecker: Type Mismatch Detection](#typechecker-type-mismatch-detection)
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
          |                             |
          v                             v
   extracted data              local Registry
          |                        |
          +--------+-------+-------+
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
  +-> { typedefs }       { Name => { expr, line, col } }
  +-> { newtypes }       { Name => { expr, line, col } }
  +-> { effects }        { Name => { line, col } }
  +-> { typeclasses }    { Name => { var_spec, methods, line, col } }
  +-> { declares }       { Name => { pkg, name, type_expr, line, col } }
  +-> { variables }      { $name => { type_expr, init_node, line, col } }
  +-> { functions }      { name => { params_expr, returns_expr, generics,
  |                                   eff_expr, param_names, line, end_line,
  |                                   col, block, unannotated } }
  +-> { ignore_lines }   { line_number => 1 }   (from @typist-ignore)
  +-> { ppi_doc }        PPI::Document object
```

### Pattern Recognition

Each extraction target has a specific PPI pattern:

```
typedef:    Statement[ Word("typedef"), Word(Name), Operator("=>"), ... ]
newtype:    Statement[ Word("newtype"), Word(Name), Operator("=>"), ... ]
effect:     Statement[ Word("effect"), Word(Name), Operator("=>"), ... ]
typeclass:  Statement[ Word("typeclass"), Word(Name), Operator("=>"), ... ]
declare:    Statement[ Word("declare"), Word(Name), Operator("=>"), Quote(expr) ]

Variable:   Statement::Variable[ Symbol($x), Operator(:), Word(Type), List(...) ]
            PPI doesn't parse variable attributes as PPI::Token::Attribute,
            so the :Type(...) pattern is reconstructed manually.

Function:   Statement::Sub[ Word(name), Token::Attribute("Type(...)"), Block ]
            Regex match: /\AType\((.+)\)\z/s on attribute content
```

### Unannotated Function Handling

Functions without `:Type()` are still extracted with:

```perl
{
    params_expr => [('Any') x $arity],   # All params are Any
    returns_expr => 'Any',
    unannotated => 1,
}
```

This enables the effect checker to flag unannotated callees.

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

`Static::TypeChecker` uses PPI AST nodes to detect three categories of type mismatches.

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
  Skip if:
    - Not followed by PPI::Structure::List (not a call)
    - Inside a PPI::Statement::Sub (it's a declaration name)
    - Function has generics (skip polymorphic calls)
    - Preceded by -> operator (method call)

  Resolve function signature:
    1. Local: extracted.functions{name}
    2. Cross-package: split "Pkg::func", registry->lookup_function(pkg, func)

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

  Implicit return:
    Get last statement of block
    Skip if: sub declaration, compound statement, or starts with 'return'
    Infer type of last expression, check against declared
```

### Scoped Environment

`_env_for_node($node)` walks up the PPI parent chain to find the enclosing function. If found, it creates a scoped environment with parameter bindings added:

```
Global env:  { variables: { $x => Int }, functions: { add => Int } }
                            +
Inside add:  { variables: { $x => Int, $a => Int, $b => Int }, ... }
```

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
          - Declared pure → skip
          - Not declared → unannotated (Eff(*))

      If local/cross-package function with argument list:
        Lookup in registry → { effects, unannotated }

  For each callee:
    If callee.unannotated:
      → EffectMismatch: "calls unannotated function X (may perform any effect)"

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

The EffectChecker maintains a hardcoded set of ~50 Perl builtins that it recognizes as potential call sites (say, print, warn, die, open, close, read, write, etc.). These are treated as unannotated unless `declare` provides an annotation.

---

## Infer: Static Type Inference

`Static::Infer` infers types from PPI elements. It is the foundation of all three TypeChecker checks.

### Public API

```perl
my $type = Typist::Static::Infer->infer_expr($ppi_element, $env);
# Returns: Type object, or undef (cannot infer)
```

### Inference Rules

```
PPI Element                    Result                    Notes
─────────────────────────────  ────────────────────────  ─────────────
PPI::Token::Number::Float      Literal(val, 'Num')
PPI::Token::Number::Exp        Literal(val, 'Num')
PPI::Token::Number (0 or 1)    Literal(val, 'Bool')
PPI::Token::Number (other)     Literal(val, 'Int')
PPI::Token::Quote              Literal(string, 'Str')   Uses ->string
PPI::Token::HereDoc            Atom('Str')
PPI::Token::Word 'undef'       Atom('Undef')
PPI::Structure::Constructor[]  Param('ArrayRef', LUB)   _infer_array
PPI::Structure::Constructor{}  Param('HashRef',S,LUB)   _infer_hash (needs =>)
PPI::Token::Symbol             env.variables{content}   Needs $env
PPI::Token::Word + List        env.functions{name}      _infer_call

Word not in env.functions
  but in env.known:            undef                    Skip (partial)
Word not in either:            Atom('Any')              Gradual fallback
```

### LUB (Least Upper Bound) for Arrays

When inferring `[1, "a", 3.14]`, the inferrer:

1. Infers each element: `Literal(1, Int)`, `Literal("a", Str)`, `Literal(3.14, Num)`
2. Promotes literals to atoms: `Int`, `Str`, `Num`
3. Computes LUB pairwise: `common_super(Int, Str)` = `Any`, etc.
4. Returns `ArrayRef[Any]`

---

## Gradual Typing Semantics

Typist implements gradual typing where annotation density determines check strictness:

### Four Annotation Levels

```
Level                    Example                               Behavior
─────────────────────    ───────────────────────────            ──────────────────────
Fully annotated          :Type((Str) -> Int !Eff(Console))     All checks active
Partial (no return)      :Type((Str) -> Any)                   Params checked, return unknown
Partial (no effect)      :Type((Str) -> Int)                   Types checked, treated as pure
Unannotated              sub foo ($x) { ... }                  Skipped (Any -> Any ! Eff(*))
```

### Implementation: The Any Guard

Every check method has an `Any` guard that prevents false positives:

```perl
# In _check_variable_initializers, _check_call_sites, _check_return_types:
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
  +-> For each file:
        Extractor->extract(source)
        _register_file_types(pkg, extracted, registry)
          +-> aliases, newtypes, effects, typeclasses, functions
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
    line     => 42,                       # Line number
    severity => 2,                        # 1=critical, 2=error, 3=warning, 4=info
}
```

### Severity Mapping

```
1 (Critical)  CycleError
2 (Error)     TypeMismatch, TypeError, ResolveError, UnknownTypeClass, EffectMismatch
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
sub handler :Type((Str) -> Str !Eff(Console)) ($s) {
    # @typist-ignore
    some_unannotated_function($s);  # No EffectMismatch
}
```

### TYPIST_CHECK_QUIET

Setting `TYPIST_CHECK_QUIET=1` skips the entire `_check_analyze()` pass in the CHECK block. Use this when `typist-lsp` provides diagnostics to avoid duplicate output.

---

## Known Limitations

### Expression Inference

| Not Supported | Example | Reason |
|---------------|---------|--------|
| Arithmetic | `$a + $b` | No expression type rules for operators |
| Ternary | `$x ? $a : $b` | No branch type merging |
| Subscript | `$arr->[0]`, `$h->{k}` | No element type extraction |
| Method calls | `$obj->method()` | No receiver type resolution (planned) |
| String interpolation | `"Hello, $name"` | PPI represents as single token |
| Regex | `$x =~ /pattern/` | Returns match result, not typed |
| Dereference | `@{$arr}`, `%{$hash}` | No deref type propagation |

### Structural

| Limitation | Impact |
|------------|--------|
| Generic calls skipped | Functions with `<T>` get zero call-site type checking |
| No arity checking | Wrong number of arguments not detected |
| No mutation tracking | Variable reassignment after init not checked |
| No control flow | if/while branches not analyzed for return types |
| No scope shadowing | Inner closures share parent's flat name env |
| PPI attribute parsing fragile | Unusual spacing in `:Type(...)` may fail |

### Effects

| Limitation | Impact |
|------------|--------|
| Open rows skipped | Row polymorphic effects not verified statically |
| No effect handlers | Effects are phantom annotations only |
| No effect inference | Effects must be manually annotated |
| Builtins default to `Eff(*)` | Every builtin call needs `declare` to avoid warnings |
