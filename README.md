# Typist

A type system for Perl, implemented in pure Perl.

Typist brings static-style type annotations to Perl 5.40+ through standard attribute syntax and `tie` mechanics — no source filters, no external tooling.

## Synopsis

```perl
use Typist;

# Type aliases
typedef Name   => 'Str';
typedef Config => '{ host => Str, port => Int }';

# Typed variables
my $count :Type(Int) = 0;
my $label :Type(Maybe[Str]) = undef;

# Typed subroutines
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
    $a + $b;
}

# Generics
sub first :Generic(T) :Params(ArrayRef[T]) :Returns(T) ($arr) {
    $arr->[0];
}
```

## Features

- **Primitive types** — `Any`, `Num`, `Int`, `Bool`, `Str`, `Undef`, `Void`
- **Parameterized types** — `ArrayRef[T]`, `HashRef[K, V]`, `Tuple[T, U, ...]`, `Ref[T]`
- **Union & Intersection** — `Int | Str`, `Readable & Writable`
- **Function types** — `CodeRef[Int, Int -> Int]`
- **Struct types** — `{ name => Str, age => Int }`
- **Maybe sugar** — `Maybe[T]` desugars to `T | Undef`
- **Named aliases** — `typedef` for reusable type definitions
- **Generics** — `:Generic(T)` with Hindley-Milner style unification
- **Structural subtyping** — width subtyping for structs, contravariant parameters for functions
- **CHECK-phase analysis** — detects alias cycles, unknown types, and undeclared type variables before runtime

## Requirements

- Perl 5.40+

## License

This is free software; you can redistribute it and/or modify it under the same terms as the Perl 5 programming language system itself.
