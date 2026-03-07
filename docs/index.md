# Typist

**A pure Perl type system for Perl 5.40+.**

Typist brings static type checking to Perl without source filters or external preprocessors. Annotate your code with `:sig()` attributes, and Typist catches type errors at compile time, in your editor, and optionally at runtime.

```perl
use v5.40;
use Typist;

BEGIN {
    struct Person => (
        name => 'Str',
        age  => 'Int',
        optional(email => 'Str'),
    );
}

sub greet :sig((Person) -> Str) ($person) {
    "Hello, " . $person->name . "!";
}

my $alice = Person(name => "Alice", age => 30);
say greet($alice);   # Hello, Alice!
```

!!! warning "Not on CPAN"
    There is an unrelated module named `Typist` on CPAN — it is **not** this project. This Typist is distributed exclusively via its [GitHub repository](https://github.com/cwd-k2/typist).

## What Typist Offers

**Static-first architecture.** Errors are caught during the CHECK phase and via the LSP server — before your program runs. Runtime enforcement is opt-in for when you need it.

**Zero runtime overhead by default.** `use Typist;` adds no performance cost to your running program. Type annotations are checked statically and then get out of the way.

**Gradual adoption.** You don't have to annotate everything at once. Typist checks what you annotate and leaves the rest alone. Start with module boundaries and work inward.

**Rich type system.** Generics with bounded quantification, algebraic data types with pattern matching, type classes with multi-dispatch, algebraic effects with row polymorphism — all in standard Perl.

## Feature Overview

| Feature | Description |
|---------|-------------|
| [Type Annotations](guide/type-annotations.md) | `:sig()` on variables and functions |
| [Structs](guide/struct.md) | Nominal, immutable, blessed record types |
| [ADTs & Pattern Matching](guide/adt.md) | Tagged unions with exhaustive `match` |
| [Generics](guide/generics.md) | Parametric polymorphism with bounds and constraints |
| [Type Classes](guide/typeclass.md) | Ad-hoc polymorphism with instance dispatch |
| [Algebraic Effects](guide/effects.md) | Tracked side effects with scoped handlers |
| [Effect Protocols](guide/effect-protocols.md) | State machine verification for effect operations |
| [Gradual Typing](guide/gradual-typing.md) | Incremental adoption — annotate at your own pace |
| [Type Narrowing](advanced/narrowing.md) | Control-flow-sensitive type refinement |
| [LSP Server](tooling/lsp.md) | Hover, completion, diagnostics, go-to-definition, and more |

## Quick Links

- **[Getting Started](getting-started/index.md)** — Install and write your first typed program
- **[Guide](guide/index.md)** — Learn the type system from the ground up
- **[Cookbook](cookbook/index.md)** — Patterns and recipes for real projects
- **[Reference](reference/index.md)** — Complete type syntax and diagnostics
- **[Internals](internal/index.md)** — Architecture, static analysis pipeline, conventions (for contributors)
