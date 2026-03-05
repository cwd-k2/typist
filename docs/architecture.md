# Typist Architecture

This document describes the internal architecture of Typist, including module dependencies, data flow, and design decisions.

> **Related documentation**: [type-system.md](type-system.md) (type theory) | [static-analysis.md](static-analysis.md) (analyzer algorithms) | [conventions.md](conventions.md) (coding conventions) | [lsp-coverage.md](lsp-coverage.md) (LSP features)

## Table of Contents

- [System Overview](#system-overview)
- [Lifecycle: From Source to Diagnostics](#lifecycle-from-source-to-diagnostics)
- [Module Dependency Graph](#module-dependency-graph)
- [Type Node Hierarchy](#type-node-hierarchy)
- [Static Analysis Pipeline](#static-analysis-pipeline)
- [Registry Design](#registry-design)
- [Error System](#error-system)
- [LSP Server Architecture](#lsp-server-architecture)
- [Runtime Enforcement](#runtime-enforcement)
- [Module Loading Strategy](#module-loading-strategy)

---

## System Overview

Typist operates across three phases of a Perl program's lifecycle:

```
 Source Code
     |
     v
+==========================================+
|  COMPILE TIME  (Perl's BEGIN/use phase)  |
|                                          |
|  use Typist;                             |
|    -> import(): register package,        |
|       install attribute handlers,        |
|       export typedef/newtype/effect/     |
|       datatype/handle/...                |
|                                          |
|  :sig(...) attributes processed:        |
|    -> Parser->parse_annotation()         |
|    -> Registry->register_function()      |
|    -> Registry->register_method()        |
|    -> [runtime only] Attribute->_wrap()  |
|                                          |
|  typedef/newtype/effect/typeclass/       |
|  datatype:                               |
|    -> Registry->define_alias()           |
|    -> Registry->register_newtype()       |
|    -> Registry->register_effect()        |
|    -> Registry->register_typeclass()     |
|    -> Registry->register_datatype()      |
+==========================================+
     |
     v
+==========================================+
|  CHECK PHASE  (after compile, before     |
|                runtime execution)        |
|                                          |
|  1. Error::Global->reset()               |
|  2. Static::Checker->analyze()           |
|     - Alias cycle detection              |
|     - Undeclared type variable check     |
|     - Kind well-formedness               |
|     - TypeClass superclass validation    |
|  3. _check_analyze()                     |
|     - require Static::Analyzer (lazy)    |
|     - For each registered package:       |
|       - Read source file                 |
|       - Install Prelude (CORE defaults)  |
|       - PPI::Document->new()             |
|       - Extractor->extract()             |
|       - Register methods                 |
|       - Register datatypes               |
|       - TypeChecker->analyze()           |
|         (assignments, arity, generics,   |
|          methods, narrowing, branches)   |
|       - EffectChecker->analyze()         |
|  4. warn Error::Global->report()         |
+==========================================+
     |
     v
+==========================================+
|  RUNTIME                                 |
|                                          |
|  Static-only (default):                  |
|    Original subs execute directly.       |
|    No tie, no wrappers. Zero overhead.   |
|                                          |
|  Runtime mode (-runtime):               |
|    Tied scalars: STORE/FETCH validate.   |
|    Wrapped subs: args + return checked.  |
|                                          |
|  Always active:                          |
|    Newtype constructors validate.        |
|    Datatype constructors validate.       |
|    Name::coerce($val) extracts inner.    |
|    Effect::op() dispatches effect ops.      |
|    handle { } scoped handler blocks.     |
+==========================================+
```

---

## Lifecycle: From Source to Diagnostics

### The `:sig()` Attribute Journey

When Perl compiles `sub add :sig((Int, Int) -> Int) ($a, $b) { ... }`:

```
Perl compiler encounters :sig(...)
     |
     v
MODIFY_CODE_ATTRIBUTES callback (Attribute.pm)
     |
     +-> Parser->parse_annotation("(Int, Int) -> Int")
     |     |
     |     +-> Tokenize: ['(', 'Int', ',', 'Int', ')', '->', 'Int']
     |     +-> Recursive descent: Func([Atom(Int), Atom(Int)], Atom(Int))
     |     +-> Return: { type => Func(...), generics_raw => [] }
     |
     +-> Detect method: first param $self → register_method
     |   Detect function: otherwise → register_function
     |
     +-> Registry->register_function('main', 'add', {
     |       params  => [Atom(Int), Atom(Int)],
     |       returns => Atom(Int),
     |       ...
     |   })
     |
     +-> [if $RUNTIME] _wrap_sub($coderef, $sig, $pkg, $name)
     |     |
     |     +-> Replace glob entry with validation closure
     |
     v
Attribute returns () — accepted
```

### The CHECK Phase Pipeline

```
CHECK block fires (Typist.pm)
     |
     +-> Error::Global->reset()
     |
     +-> Static::Checker->new->analyze()
     |     |
     |     +-> _check_aliases()      # Resolve each alias, detect cycles
     |     +-> _check_functions()    # Free vars, bounds, kinds per function
     |     +-> _check_typeclasses()  # Superclass existence + cycle detection
     |
     +-> _check_analyze()  [unless $CHECK_QUIET]
           |
           +-> require Static::Analyzer  (first PPI load)
           |
           +-> for each package in Registry->all_packages:
                 |
                 +-> _package_to_file()  # main -> $0, Foo::Bar -> $INC{"Foo/Bar.pm"}
                 +-> _slurp($file)       # Read source
                 |
                 +-> Analyzer->analyze($source, workspace_registry => ...)
                       |
                       +--[ Prelude Phase ]--------+
                       |  Prelude->install(registry) |
                       |    Register IO, Exn, Decl    |
                       |    Register CORE:: builtins |
                       +----------------------------+
                       |
                       +--[ Extraction Phase ]------+
                       |  Extractor->extract($src)   |
                       |    PPI::Document->new(\$s)  |
                       |    Extract: aliases,         |
                       |      newtypes, datatypes,    |
                       |      effects, typeclasses,   |
                       |      declares, variables,    |
                       |      functions (with method  |
                       |      detection), ignore lines|
                       +----------------------------+
                       |
                       +--[ Registration Phase ]----+
                       |  Register typedefs          |
                       |  Register newtypes          |
                       |  Register datatypes         |
                       |  Register effects           |
                       |  Register typeclasses       |
                       |  Register declares          |
                       |  Register functions         |
                       |  Register methods           |
                       +----------------------------+
                       |
                       +--[ Check Phase ]------------+
                       |  Checker->analyze()          |
                       |  TypeChecker->analyze()      |
                       |    _check_variable_init      |
                       |    _check_assignments        |
                       |    CallChecker (delegate)    |
                       |      (arity, generic unify,  |
                       |       method/struct calls)   |
                       |    _check_return_types       |
                       |      (explicit + implicit    |
                       |       branch analysis)       |
                       |    NarrowingEngine           |
                       |      (defined/isa/ref guards,|
                       |       early return, accessor)|
                       |  EffectChecker->analyze()    |
                       +-----------------------------+
                       |
                       +-> Return { diagnostics, symbols, extracted, registry }
```

---

## Module Dependency Graph

### Core Type System

```
                       Typist::Type  (abstract base, overloads)
                            |
  +------+------+------+---+---+------+--------+--------+------+
  |      |      |      |       |      |        |        |      |
Atom   Param  Union  Intersect Func  Record  Struct    Var  Quantified
  |                              |      |        |             |
(pool)                       (effects)(structural)(nominal)  (forall)

  +--------+--------+-------+-------+-------+-------+
  |        |        |       |       |       |       |
Alias   Literal  Newtype   Data    Row     Eff    Fold
                             |       |       |       |
                         (variants)(labels)(wraps Row)(traversal)
```

### Module Loading DAG

```
Typist.pm (entry point)
  |
  +-- Type::* (16 modules)          Always loaded
  |     +-- Type::Data              Tagged unions (ADT)
  |     +-- Type::Quantified        Rank-2 polymorphism (forall)
  |     +-- Type::Fold              map_type / walk traversals
  +-- Effect, TypeClass             Always loaded
  +-- Kind, KindChecker             Always loaded
  +-- Parser                        Always loaded
  +-- Registry                      Always loaded
  +-- Subtype                       Always loaded
  +-- Inference                     Always loaded
  +-- Handler                       Always loaded (effect handler stack)
  +-- Attribute                     Always loaded
  |     +-- B (Perl introspection)
  |     +-- Transform
  |     +-- Tie::Scalar
  +-- Static::Checker               Always loaded
  |     +-- Type::Fold
  +-- Error, Error::Global          Always loaded
  +-- DSL                           Always loaded
  |
  +-- Static::Analyzer              LAZY (require in CHECK)
  |     +-- Prelude                 Builtin type annotations
  |     +-- Static::Extractor
  |     |     +-- PPI               <-- Heavy dependency, lazy
  |     +-- Static::TypeChecker     Env, var/return checks, coordination
  |     |     +-- Static::CallChecker      Call-site type checking
  |     |     +-- Static::NarrowingEngine  Control flow narrowing
  |     |     +-- Static::Infer
  |     |     +-- Static::Unify     Generic instantiation
  |     +-- Static::EffectChecker
  |     +-- Static::ProtocolChecker
  |
  +-- Prelude                       LAZY (via Analyzer, Workspace)
```

### LSP Module Graph

```
Typist::LSP (entry point, bin/typist-lsp)
  |
  +-- LSP::Server
  |     +-- LSP::Transport        JSON-RPC framing
  |     +-- LSP::Document         Per-file analysis cache
  |     |     +-- Document::Resolver  Accessor chain type resolution
  |     +-- LSP::Workspace        Cross-file registry
  |     |     +-- Prelude         Builtin annotations for workspace
  |     +-- LSP::Hover            Type signature display
  |     +-- LSP::Completion       Type name suggestions
  |     +-- LSP::CodeAction       Quickfix suggestions
  |     +-- LSP::SemanticTokens   Syntax-aware token classification
  |     +-- LSP::Logger           Configurable logging
  |     +-- Static::Analyzer      Full analysis pipeline
  |           +-- (all Static::* modules)
  |
  +-- Registry (instance-based)
  +-- Error::Collector (instance-based)
```

---

## Type Node Hierarchy

### Abstract Interface

Every `Typist::Type` subclass implements:

```
Method          Returns         Purpose
──────────────  ──────────────  ────────────────────────────────
name()          Str             Type name (e.g., "Int", "ArrayRef")
to_string()     Str             Human-readable representation
equals($other)  Bool            Structural equality
contains($val)  Bool            Runtime value membership test
free_vars()     List[Str]       Unbound type variable names
substitute(\%)  Type            Apply binding map, return new type
```

### Type Lattice

```
                        Any
                      / | \ \
                   Str Num  |  Void  Undef
                        |   |
                     Double  |
                        |    |
                       Int   |
                        |    |
                      Bool   |
                        |    |
                      Never


  Structural:

    Param[T...]        ArrayRef[Int] (Array[Int]), HashRef[Str, Num] (Hash[Str, Num])
    Union(T|U)         Int | Str
    Intersection(T&U)  Readable & Writable
    Func(P->R!E)       (Int, Int) -> Int ![Console]
    Record{k:T}        { name => Str, age? => Int }  — structural composite

  Nominal:

    Struct(name,fields)  struct 'Point' => (x => Int, y => Int)  — nominal composite
    Newtype(name,T)      Nominal wrappers — name-based identity
    Data(name,vars)      Tagged unions — nominal ADT with constructors
    Alias(name)          typedef references — lazy resolution
    Literal(val,base)    42:Int, "hi":Str — singleton types

  Quantification:

    Quantified(vars,body)  forall A. (A) -> A  — rank-2 polymorphism
    Var(name,bound,kind)   T, U:Num, F:*->*

  Effect:

    Row(labels,var)    Sorted effect labels + optional tail var
    Eff(Row)           Wrapper for function effect annotations

  Meta:

    Fold               map_type (bottom-up), walk (top-down)  — traversal utility
```

### Subtyping Rules

```
Rule                  Notation                    Implementation
────────────────────  ────────────────────────     ──────────────────
Identity              T <: T                      equals()
Top                   T <: Any                    Always true
Bottom                Never <: T                  Always true
Void                  Void <: Any only            No other supertypes
Alias                 resolve then compare        Registry lookup
Union (sub)           T|U <: S iff T<:S & U<:S    All members subtype
Union (super)         S <: T|U iff S<:T | S<:U    Any member subtype
Intersection (sub)    T&U <: S iff T<:S | U<:S    Any member subtype
Intersection (super)  S <: T&U iff S<:T & S<:U    All members subtype
Newtype               N <: N iff same name        Nominal identity
Data                  D <: D iff same name        Nominal identity
Literal-Literal       L1 <: L2 iff val= & base<:  Value + hierarchy
Literal-Atom          L <: A iff L.base <: A      Promotion
Atom                  A <: B iff A in ancestors(B) %PARENT chain (Bool<:Int<:Double<:Num<:Any)
Param                 P[A] <: P[B] iff A<:B       Covariant
Func params           (A)->R <: (B)->R iff B<:A   Contravariant
Func return           (A)->R <: (A)->S iff R<:S   Covariant
Func effects          ..!E1 <: ..!E2 iff E1<:E2   Covariant
Record                {a,b,c} <: {a,b}            Width subtyping (structural)
Struct                S <: S iff same name         Nominal identity (covariant args)
Struct-Record         S <: {a,b} via inner record  Structural compatibility
Record-Struct         {a,b} </: S                  Nominal barrier
Quantified            (forall A. T) <: U           Instantiation
Row                   Row(A,B) <: Row(A)           Label inclusion
```

---

## Static Analysis Pipeline

### Analyzer Orchestration (per-file)

```
Analyzer.analyze($source, workspace_registry => $ws_reg)
  |
  +-- 1. Merge workspace registry
  |       $registry->merge($ws_reg)
  |
  +-- 1b. Install Prelude
  |       Prelude->install($registry)
  |         +-> Register IO, Exn effect labels
  |         +-> Register CORE:: builtin annotations
  |
  +-- 2. Extract from PPI
  |       Extractor->extract($source)
  |         -> { aliases, newtypes, datatypes, effects, typeclasses,
  |              declares, variables, functions (with method detection),
  |              ignore_lines, package, ppi_doc }
  |
  +-- 3. Register extracted data into local registry
  |       for each typedef:   registry->define_alias(name, expr)
  |       for each newtype:   registry->register_newtype(name, type)
  |       for each datatype:  registry->register_datatype(name, type)
  |       for each effect:    registry->register_effect(name, eff)
  |       for each typeclass: registry->register_typeclass(name, def)
  |       for each declare:   registry->register_function(pkg, name, sig)
  |       for each function:  registry->register_function(pkg, name, sig)
  |       for each method:    registry->register_method(pkg, name, sig)
  |
  +-- 4. Structural checks
  |       Checker->new(registry => $registry, errors => $errors)
  |         ->analyze()
  |
  +-- 5. Type mismatch checks
  |       TypeChecker->new(
  |         extracted => $extracted,
  |         registry  => $registry,
  |         ppi_doc   => $ppi_doc,
  |         errors    => $errors,
  |         file      => $file,
  |       )->analyze()
  |
  +-- 6. Effect mismatch checks
  |       EffectChecker->new(
  |         extracted => $extracted,
  |         registry  => $registry,
  |         ppi_doc   => $ppi_doc,
  |         errors    => $errors,
  |         file      => $file,
  |       )->analyze()
  |
  +-- 7. Enrich diagnostics with file/line info
  |       _to_diagnostics($errors, $extracted, $file)
  |
  +-- 8. Return result
        { diagnostics, symbols, extracted, registry }
```

### TypeChecker Internal Flow

```
TypeChecker->analyze()
  |
  +-- _build_env()
  |     |
  |     +-- Load annotated variables into env.variables
  |     +-- Load function return types into env.functions
  |     +-- Mark annotated names in env.known
  |     +-- Infer unannotated variable types via Infer->infer_expr()
  |
  +-- _check_variable_initializers()
  |     |
  |     for each variable with init_node:
  |       inferred = Infer->infer_expr(init_node, env)
  |       declared = resolve(type_expr)
  |       if !Subtype->is_subtype(inferred, declared):
  |         collect TypeMismatch
  |
  +-- _check_assignments()
  |     |
  |     for each '=' operator in document:
  |       skip unless annotated variable, skip variable declarations
  |       inferred = Infer->infer_expr(RHS, env)
  |       if !Subtype->is_subtype(inferred, declared):
  |         collect TypeMismatch
  |
  +-- _check_call_sites()
  |     |
  |     for each PPI::Token::Word in document:
  |       if preceded by ->: delegate to _check_method_call
  |       resolve: local function / cross-package / CORE builtin
  |       skip if not a function call (no following List)
  |       arity check (ArityMismatch if wrong count)
  |       if generic: delegate to _check_generic_call (Unify)
  |       env = _env_for_node(word)  # scoped + narrowed
  |       for each arg up to min(params, args):
  |         inferred = Infer->infer_expr(arg, env)
  |         if !Subtype->is_subtype(inferred, param_type):
  |           collect TypeMismatch
  |
  +-- _check_return_types()
        |
        for each function with returns_expr and block:
          explicit returns: find 'return' keywords, check each
          implicit return: _check_implicit_return_of_stmt
            recursively walks if/else/while/for branches
```

### EffectChecker Internal Flow

```
EffectChecker->analyze()
  |
  for each annotated function (skip unannotated):
    |
    caller_eff = registry->lookup_function(pkg, name).effects
    |
    +-- _collect_called_effects(function_block)
    |     |
    |     for each PPI::Token::Word in block:
    |       skip keywords, sub names, method calls, hash keys
    |       |
    |       if builtin (say, print, die, ...):
    |         check CORE registry (Prelude or declare):
    |           declared with effects → use those
    |           declared pure → skip
    |           no declaration → unannotated => 1
    |       |
    |       if local/cross-package function with arg list:
    |         lookup in registry
    |         return { name, effects, unannotated, line }
    |
    +-- for each callee:
          if callee.unannotated:
            collect EffectMismatch (may perform any effect)
          if caller has no effects but callee does:
            collect EffectMismatch (pure calls effectful)
          if both have closed rows:
            _check_effect_inclusion(caller_row, callee_row)
              if callee labels not subset of caller labels:
                collect EffectMismatch
```

### Type Inference Capabilities

```
Expression Form              Inferred Type         Module
───────────────────────────  ────────────────────  ─────────────
42, 0, 1                     Literal(val, base)    Infer._infer_number (Bool/Int)
3.14, 1e10                   Literal(val,'Double') Infer._infer_number
"hello", 'world'             Literal(val, 'Str')   Infer
"Hello, $name"               Atom('Str')           Infer (interpolated → Str)
<<HEREDOC                    Atom('Str')           Infer
undef                        Atom('Undef')         Infer
[1, 2, 3]                   Param('ArrayRef', T)  Infer._infer_array
+{ k => v }                  Param('HashRef',S,T)  Infer._infer_hash
$variable                    env lookup            Infer
$arr->[0]                    ArrayRef[T] → T       Infer._infer_subscript
$h->{k}                      HashRef → V / Struct  Infer._infer_subscript
func(args)                   env.functions{func}   Infer._infer_call
CORE::name(args)             Prelude returns type  Infer._infer_call
$a + $b                      Atom('Num')           Infer._infer_binop
$a . $b                      Atom('Str')           Infer._infer_binop
$a == $b                     Atom('Bool')          Infer._infer_binop
$a =~ /pat/                  Atom('Bool')          Infer._infer_binop
!$x                          Atom('Bool')          Infer._infer_operator
$x ? $a : $b                 LUB or Union          Infer._infer_ternary

NOT SUPPORTED:
@{$arr}, %{$hash}            -                     Dereference
```

---

## Registry Design

### Dual-Mode Operation

The Registry supports both class methods (singleton, for CHECK phase and runtime) and instance methods (for LSP, per-workspace):

```
Class Mode (Singleton)              Instance Mode
─────────────────────               ──────────────
Typist::Registry->register(...)     $reg = Typist::Registry->new
  |                                 $reg->register(...)
  v                                   |
$DEFAULT //= Typist::Registry->new    v
$DEFAULT->{...}                     $self->{...}
```

The `_self` helper dispatches: `ref $invocant ? $invocant : $invocant->_default`.

### Storage Structure

```
Registry
  |
  +-- {packages}    { "main" => 1, "Foo::Bar" => 1 }
  +-- {aliases}     { "Name" => "Str", "Config" => "{ host => Str }" }
  +-- {resolved}    { "Name" => Atom(Str) }                    # Cache
  +-- {resolving}   { "Name" => 1 }                            # Cycle guard
  +-- {variables}   { "$ref_addr" => { type => ..., name => ... } }
  +-- {functions}   { "main::add" => { params => [...], returns => ..., effects => ... } }
  +-- {methods}     { "Pkg::name" => { params => [...], returns => ..., ... } }
  +-- {newtypes}    { "UserId" => Newtype("UserId", Atom(Int)) }
  +-- {datatypes}   { "Shape" => Data("Shape", { Circle => [...], ... }) }
  +-- {typeclasses} { "Show" => TypeClass::Def { ... } }
  +-- {instances}   { "Show" => [TypeClass::Inst { type_expr => "Int", ... }, ...] }
  +-- {effects}     { "Console" => Effect { name => "Console", operations => {...} } }
```

### Cross-File Support via Merge

```
Workspace Registry (shared)     Local Registry (per-file)
      |                               |
      |   merge($ws_reg)              |
      +------------------------------>+
      |   copies: aliases, newtypes,  |
      |   datatypes, effects,         |
      |   typeclasses, functions,     |
      |   methods, instances          |
      |   clears: resolved (cache)    |
                                      |
                                 Analyzer uses local
                                 registry for all lookups
```

---

## Error System

### Two-Tier Design

```
Error (value class)                  Error::Collector (instance)
  |                                    |
  +-- kind: Str                        +-- @errors: [Error, ...]
  +-- message: Str                     +-- collect(%args): push
  +-- file: Str                        +-- has_errors(): Bool
  +-- line: Int                        +-- report(): Str
                                       +-- reset(): clear

Error::Global (singleton)
  |
  +-- @ERRORS: package-scoped
  +-- Same API as Collector
  +-- Used by CHECK phase
  +-- LSP uses Collector instances instead
```

### Diagnostic Kinds and Severities

```
Severity 1 (Critical):
  CycleError           Alias or typeclass inheritance cycle

Severity 2 (Error):
  TypeMismatch         Value/argument type doesn't match declaration
  ArityMismatch        Wrong number of arguments at call site
  TypeError            General type error
  ResolveError         Cannot resolve type reference
  UnknownTypeClass     Referenced typeclass not found
  EffectMismatch       Callee effects not covered by caller

Severity 3 (Warning):
  UndeclaredTypeVar    Type variable not in generic list
  UndeclaredRowVar     Row variable not in generic list
  UnknownEffect        Effect label not registered

Severity 4 (Info):
  UnknownType          Referenced type not found (low severity)
```

---

## LSP Server Architecture

### Message Flow

```
Editor (Neovim/VS Code)
  |
  | stdin (JSON-RPC, Content-Length framing)
  v
Transport (read_message / write_message)
  |
  v
Server (dispatch loop)
  |
  +-- initialize       -> capabilities, workspace scan
  +-- textDocument/didOpen    -> Document.analyze -> publish diagnostics
  +-- textDocument/didChange  -> Document.invalidate -> re-analyze
  +-- textDocument/didSave    -> re-diagnose all open docs (cross-file)
  +-- textDocument/hover      -> Hover.provide(doc, position)
  +-- textDocument/completion -> Completion.provide(doc, position)
  +-- textDocument/definition -> Definition lookup
  +-- textDocument/signatureHelp -> Signature display
  +-- textDocument/documentSymbol -> Symbol list
  +-- textDocument/inlayHint  -> Inlay hints
  +-- shutdown / exit         -> clean shutdown
  |
  | stdout (JSON-RPC responses)
  v
Editor
```

### Workspace Scanning

```
Workspace.scan(root_path)
  |
  +-- Install Prelude into registry
  |
  +-- File::Find all *.pm under root
  |
  +-- for each file:
  |     Extractor->extract(source)
  |     _register_file_types(extracted)
  |       +-- register aliases
  |       +-- register newtypes
  |       +-- register datatypes
  |       +-- register effects
  |       +-- register typeclasses
  |       +-- register declares
  |       +-- register functions (with parsed types)
  |       +-- register methods
  |     Store extracted data for rebuild
  |
  +-- Workspace.update_file(uri, source)  [on save]
        +-- delete stale file entry
        +-- _rebuild_registry()  # re-register from all stored
        +-- process new source
```

### Document Lifecycle

```
didOpen(uri, text)
  +-> Document.new(uri, text, workspace)
  +-> Document.analyze()
  |     +-> Analyzer->analyze(text, workspace_registry => ws.registry)
  |     +-> Cache result (diagnostics, symbols, extracted)
  +-> Server.publish_diagnostics(uri, diagnostics)

didChange(uri, changes)
  +-> Document.update(text)
  +-> Document.invalidate()

didSave(uri)
  +-> Workspace.update_file(uri, text)
  +-> For each open document:
        Document.invalidate()
        Document.analyze()
        Server.publish_diagnostics(uri, diagnostics)
```

---

## Runtime Enforcement

### Tied Scalar (Typist::Tie::Scalar)

```
tie $$ref, 'Typist::Tie::Scalar', type => $type, value => $initial

STORE($value):
  $type->contains($value) or die
  $self->{value} = $value

FETCH():
  return $self->{value}
```

### Wrapped Sub (Attribute._wrap_sub)

```
Original: sub add($a, $b) { $a + $b }

Wrapped:
  sub {
    my @args = @_;

    # Generic instantiation (if generic)
    if (@generics) {
      @types = map { Inference->infer_value($_) } @args;
      $bindings = Inference->instantiate($sig, @types);
      # Check bounds
      for each generic with bound:
        die unless Subtype->is_subtype($actual, $bound);
    }

    # Parameter type check
    for each param:
      die unless $ptype->contains($args[$i]);

    # Call original
    my @result = $original->(@args);    # Always list context

    # Return type check
    die unless $rtype->contains($result[0]);

    return wantarray ? @result : $result[0];
  }
```

### Effect Handler Stack (Typist::Handler)

```
@HANDLER_STACK: LIFO stack of { effect => name, handlers => { op => sub } }

push_handler(effect, handlers):
  push onto stack

find_handler(effect):
  reverse search stack for matching effect name

Effect::op(@args):
  find_handler(effect) -> call handlers->{op}->(@args)
  die if no handler found

handle { BODY } Effect => +{ ... }:
  push handlers
  eval { BODY }
  pop handlers (even on exception)
  re-raise if exception
```

### Cost Summary

```
                    Static-only    Runtime mode
                    ───────────    ────────────
Per scalar read     0              1 method dispatch + hash deref
Per scalar write    0              1 method dispatch + contains()
Per function call   0              N * contains() + 1 * contains()
Per generic call    0              N * infer_value + instantiate +
                                   N * parse(bound) + N * is_subtype
Newtype construct   contains()     contains()         (always active)
Datatype construct  arity+types    arity+types        (always active)
Effect::op/handle   stack ops      stack ops          (always active)
```

---

## Module Loading Strategy

### Eager vs. Lazy Loading

```
EAGER (loaded with `use Typist`):
  36 modules — all Type::* (including Data, Fold), Parser, Registry,
  Subtype, Attribute, Handler, etc.
  These are needed for compile-time attribute processing.

LAZY (loaded only when needed):
  PPI             — via require Static::Analyzer in CHECK phase
  Prelude         — via use in Analyzer/Workspace
  Static::Analyzer — via require in _check_analyze()
  Static::Extractor — via use in Analyzer (transitively lazy)
  Static::TypeChecker — via use in Analyzer
  Static::EffectChecker — via use in Analyzer
  Static::Infer   — via use in TypeChecker
  Static::Unify   — via use in TypeChecker

NEVER (unless LSP):
  LSP::*          — only loaded by bin/typist-lsp
  JSON::PP        — only needed for LSP transport
```

### Rationale

PPI is the heaviest dependency (~1MB of code, creates full ASTs). By loading it lazily via `require` inside the CHECK block, programs that use `TYPIST_CHECK_QUIET=1` (when the LSP provides diagnostics instead) avoid the PPI startup cost entirely.

The eagerly-loaded modules are lightweight: they define type node classes (small hashref-based objects), the parser (pure Perl recursive descent), and the registry (hash-based storage). This is the minimum needed to process `:sig()` attributes at compile time.

---

## Design Principles

1. **Static-first**: errors caught before runtime; runtime enforcement is opt-in
2. **Immutable types**: type nodes are value objects; `substitute` returns new nodes
3. **Flyweight atoms**: singleton semantics via `%POOL` for primitive types
4. **Normalized constructors**: Union/Intersection flatten and deduplicate
5. **Lazy heavy deps**: PPI loaded only in CHECK phase, never at runtime
6. **Dual-mode Registry**: class methods for singleton (CHECK), instance methods for LSP
7. **Gradual typing**: annotation density determines check strictness; `Any` bypasses checks
8. **Boundary enforcement**: newtype and datatype constructors always validate, independent of mode
9. **No source filters**: standard Perl attributes + PPI parsing for static analysis
10. **Effect handlers**: `Effect::op(...)`/`handle` provide dynamic-scope effect dispatch at runtime
