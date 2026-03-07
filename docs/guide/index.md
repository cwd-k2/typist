# Guide

This section walks you through the Typist type system from first principles to advanced features. Each page is self-contained but builds on concepts introduced earlier. If you are new to Typist, follow the reading order below.

## Reading Order

| # | Page | Description |
|---|------|-------------|
| 1 | [Type Annotations](type-annotations.md) | The `:sig()` attribute -- the single syntax for all type annotations |
| 2 | [Type Hierarchy](type-hierarchy.md) | Primitive types, compound types, unions, records, literals, and their subtype relations |
| 3 | [typedef and newtype](typedef-newtype.md) | Structural aliases versus nominal wrappers -- when and how to use each |
| 4 | [Structs](struct.md) | Nominal, immutable, blessed record types with optional fields and generics |
| 5 | [ADTs and Pattern Matching](adt.md) | Tagged unions with `datatype`, `enum`, and exhaustive `match` |
| 6 | [Generics](generics.md) | Parametric polymorphism with bounded quantification and type inference |
| 7 | [Type Classes](typeclass.md) | Ad-hoc polymorphism with instance dispatch and superclass hierarchies |
| 8 | [Algebraic Effects](effects.md) | Tracked side effects with scoped handlers and the effect row system |
| 9 | [Effect Protocols](effect-protocols.md) | State machine verification for effect operations |
| 10 | [Gradual Typing](gradual-typing.md) | Incremental adoption -- annotate at your own pace |
| 11 | [Static vs Runtime](static-vs-runtime.md) | The two enforcement modes and what each checks |

## Prerequisites

You should have Typist installed and working. If not, see [Getting Started](../getting-started/index.md) first.

All code examples assume:

```typist
use v5.40;
use Typist;
```

Type definitions (`typedef`, `newtype`, `struct`, `datatype`, `effect`, `typeclass`, `instance`) must appear inside `BEGIN` blocks so they are visible during compile-time analysis and cross-file tooling.
