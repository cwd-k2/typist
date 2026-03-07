# Cookbook

Practical patterns and recipes for using Typist in real projects. Each page addresses a specific problem area with complete, working code examples.

These recipes assume familiarity with the basics covered in the [Guide](../guide/index.md). All examples use `use v5.40; use Typist;` and place type definitions in `BEGIN` blocks.

## Recipes

| Page | Description |
|------|-------------|
| [Domain Modeling](domain-modeling.md) | Opaque newtypes, rich structs, state machines with ADTs, and compositional domain types |
| [Error Handling](error-handling.md) | Result and Option types, effect-based error handling, combining results with effects |
| [Multi-File Projects](multifile.md) | Shared type modules, cross-file resolution, namespace model, ImportHint diagnostics |
| [Gradual Migration](migration.md) | Step-by-step migration of existing Perl code, before/after examples, CI integration |

## Conventions Used

- All type definitions appear in `BEGIN` blocks (required for CHECK-phase visibility).
- String syntax is used for type expressions: `'Int'`, not bare `Int`.
- `+{}` is used for hashref literals to avoid block/hashref ambiguity.
- No comma after blocks in `handle`/`map`/`grep` (prototype rule).
