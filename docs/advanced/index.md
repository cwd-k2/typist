# Advanced

This section covers advanced type system features that build on the concepts introduced in the [Guide](../guide/index.md). These topics are not required for everyday use of Typist, but they unlock the full power of the type system for library authors, framework designers, and anyone working with complex type-level abstractions.

## Topics

| Page | Description |
|------|-------------|
| [Rank-2 Polymorphism](rank2.md) | Universal quantification over function arguments -- when the callee, not the caller, chooses the type |
| [Higher-Kinded Types](hkt.md) | Kinds, type constructors, and abstracting over parameterized types like `ArrayRef` |
| [Type Narrowing](narrowing.md) | Control-flow-sensitive type refinement via `defined`, `isa`, `ref`, truthiness, and early return |
| [Subtyping Rules](subtyping.md) | The complete subtype relation -- every rule, explained |
| [Recursive Types](recursive-types.md) | Self-referential type aliases through type constructors |

## Prerequisites

You should be comfortable with:

- The `:sig()` annotation syntax ([Type Annotations](../guide/type-annotations.md))
- Generics and bounded quantification ([Generics](../guide/generics.md))
- Type classes ([Type Classes](../guide/typeclass.md))
- Union and intersection types ([Type Hierarchy](../guide/type-hierarchy.md))

All code examples assume:

```typist
use v5.40;
use Typist;
```

Type definitions (`typedef`, `newtype`, `struct`, `datatype`, `effect`, `typeclass`, `instance`) must appear inside `BEGIN` blocks so they are visible during CHECK-phase static analysis.
