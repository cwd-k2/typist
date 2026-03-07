# Type Expression Syntax

Complete reference for Typist's type expression language and `:sig()` annotation syntax.

## Tokens

| Token | Meaning | Example |
|-------|---------|---------|
| Capitalized word | Type name (atom, alias, or constructor) | `Int`, `Str`, `ArrayRef`, `Person` |
| Single uppercase letter | Type variable | `T`, `U`, `V` |
| `[T, U]` | Type parameters | `ArrayRef[Int]`, `HashRef[Str, Int]` |
| `\|` | Union | `Int \| Str` |
| `&` | Intersection | `Readable & Writable` |
| `+` | Intersection (alternative, used in constraints) | `Num + Show` |
| `->` | Function arrow | `(Int) -> Str` |
| `(T, U)` | Parameter list | `(Int, Str) -> Bool` |
| `![E1, E2]` | Effect row | `-> Void ![Console, Logger]` |
| `<T>` | Generic parameter declaration | `<T>(T) -> T` |
| `<T: Bound>` | Bounded generic | `<T: Num>(T) -> T` |
| `<T: A + B>` | Compound constraint (intersection) | `<T: Num + Show>` |
| `...Type` | Variadic parameter | `(Str, ...Any)` |
| `forall A.` | Rank-2 quantifier | `forall A. (A -> A) -> A -> A` |
| `{ k => T }` | Record type | `{ name => Str, age => Int }` |
| `k? => T` | Optional field in record | `{ name => Str, age? => Int }` |
| `=>` | Field separator (records) | `{ x => Int }` |
| `!` | Effect separator (after return type) | `-> Void ![IO]` |
| `:` | Constraint separator (in generics) | `<T: Num>` |
| `.` | Body separator (in `forall`) | `forall A. A -> A` |
| `<`, `>` | Protocol state annotation in effect rows | `![DB<Idle -> Active>]` |
| `*` | Ground state (in protocol annotations) | `![DB<* -> Open>]` |

## Grammar

```
type_expr       = union_expr
union_expr      = intersect_expr ('|' intersect_expr)*
intersect_expr  = primary_type ('&' primary_type)*
                | primary_type ('+' primary_type)*
primary_type    = atom
                | param_type
                | func_type
                | record_type
                | literal
                | quantified
                | '(' type_expr ')'

atom            = 'Int' | 'Str' | 'Bool' | 'Double' | 'Num'
                | 'Any' | 'Void' | 'Never' | 'Undef'
                | Name                              -- alias (multi-char) or var (single upper)

param_type      = Name '[' type_expr (',' type_expr)* ']'

func_type       = '(' param_list? ')' '->' type_expr effects?
param_list      = variadic? type_expr (',' variadic? type_expr)*
variadic        = '...'

record_type     = '{' field (',' field)* '}'
field           = name '=>' type_expr
                | name '?' '=>' type_expr           -- optional field

effects         = '!' '[' label_list ']'
label_list      = (label_or_var (',' label_or_var)*)?
label_or_var    = Label state_annot?                -- uppercase-initial = label
                | var                               -- lowercase = row variable
state_annot     = '<' state_set ('->' state_set)? '>'
state_set       = state ('|' state)*
state           = Name | '*'

literal         = number                            -- Int or Double based on '.'
                | quoted_string                     -- Str

quantified      = 'forall' var_decl+ '.' type_expr
var_decl        = Name (':' bound)?
bound           = Name ('+' Name)*

annotation      = generics? func_type
                | generics? type_expr               -- variable annotation
generics        = '<' generic_param (',' generic_param)* '>'
generic_param   = Name
                | Name ':' constraint
constraint      = Name ('+' Name)*                  -- typeclass or bound type
                | 'Row'                             -- row variable kind
                | kind_expr                         -- HKT kind (e.g., '* -> *')
kind_expr       = kind_primary ('->' kind_primary)*
kind_primary    = '*' | 'Row'
```

### Name Resolution Rules

The parser resolves bare names according to these rules:

1. **Primitive names** (`Int`, `Str`, `Bool`, `Double`, `Num`, `Any`, `Void`, `Never`, `Undef`) resolve to `Type::Atom`.
2. **Single uppercase letter** (`T`, `U`, `V`, ...) resolves to `Type::Var` (type variable).
3. **Multi-character capitalized names** (`Person`, `Maybe`, `TreeNode`) resolve to `Type::Alias`, which is later resolved against the registry.

### Operator Precedence

From lowest to highest:

1. `|` -- union (left-associative)
2. `&` / `+` -- intersection (left-associative)
3. Primary types -- atoms, parameterized, function, record, literal, quantified, grouped

## Annotation Syntax (`:sig()`)

The `:sig()` attribute is the primary way to annotate functions and variables in Typist.

### Variable Annotations

```perl
my $name :sig(Str) = "Alice";
my $count :sig(Int) = 0;
my $items :sig(ArrayRef[Str]) = [];
my $lookup :sig(HashRef[Str, Int]) = {};
```

### Function Annotations

```perl
# Simple function
sub greet :sig((Str) -> Str) ($name) { ... }

# Multiple parameters
sub add :sig((Int, Int) -> Int) ($a, $b) { ... }

# Void return
sub log_msg :sig((Str) -> Void ![IO]) ($msg) { ... }

# Generic function
sub identity :sig(<T>(T) -> T) ($x) { ... }

# Bounded generic
sub double :sig(<T: Num>(T) -> T) ($x) { ... }

# Compound constraint
sub show_sum :sig(<T: Num + Show>(T, T) -> Str) ($a, $b) { ... }

# Effectful function
sub read_file :sig((Str) -> Str ![IO]) ($path) { ... }

# Generic with effects
sub process :sig(<T: Num>(T, T) -> T ![Console]) ($a, $b) { ... }

# Variadic
sub printf :sig((Str, ...Any) -> Void ![IO]) ($fmt, @args) { ... }

# Row-polymorphic effects
sub wrap :sig(<T, r: Row>(T) -> T ![Console, r]) ($x) { ... }

# Higher-kinded type
sub fmap :sig(<F: * -> *, A, B>((A) -> B, F[A]) -> F[B]) ($f, $fa) { ... }
```

### Annotation Components

A full function annotation has the form:

```
<Generics>(Params) -> Return ![Effects]
```

Each component is optional except the parameter list and return type:

| Component | Syntax | Required |
|-----------|--------|----------|
| Generics | `<T>`, `<T: Num>`, `<T, U>` | No |
| Parameters | `(Int, Str)`, `()`, `(Int, ...Str)` | Yes (for functions) |
| Arrow | `->` | Yes (for functions) |
| Return type | `Int`, `Void`, `ArrayRef[Str]` | Yes (for functions) |
| Effects | `![IO]`, `![IO, Console]` | No |

## Type Expression Examples

### Primitive Types

```
Int                                  # Integer
Str                                  # String
Bool                                 # Boolean
Double                               # Floating-point
Num                                  # Numeric supertype (Int <: Num, Double <: Num)
Any                                  # Top type (everything is a subtype)
Void                                 # No meaningful return value
Never                                # Bottom type (no values)
Undef                                # Perl's undef
```

### Parameterized Types

```
ArrayRef[Int]                        # Array reference of integers
HashRef[Str, Int]                    # Hash reference: string keys, integer values
Maybe[Str]                           # Str | Undef (sugar)
Tuple[Int, Str, Bool]                # Fixed-length tuple
Ref[Int]                             # Reference to Int
CodeRef[Int -> Str]                  # Function reference
Array[Int]                           # List type (distinct from ArrayRef)
Hash[Str, Int]                       # List type (distinct from HashRef)
```

### Composite Types

```
Int | Str                            # Union: Int or Str
Int | Str | Undef                    # Three-way union
Readable & Writable                  # Intersection
(Int, Str) -> Bool                   # Function type
(Int, Str) -> Bool ![IO]             # Effectful function type
{ name => Str, age => Int }          # Record type
{ name => Str, age? => Int }         # Record with optional field
```

### Literal Types

```
0 | 1 | 2                           # Integer literal union
"ok" | "error"                       # String literal union
3.14                                 # Double literal
42                                   # Int literal
```

### Quantified Types

```
forall A. A -> A                     # Rank-2: identity
forall A. (A -> A) -> A -> A         # Rank-2: function application
forall A: Num. A -> A                # Bounded rank-2
forall A: Printable + Ord. A -> A    # Compound bounded rank-2
```

### User-Defined Types

```
Person                               # Struct type (nominal)
Tree[Int]                            # Generic struct
Maybe[Person]                        # Parameterized with user type
Result[Str, Int]                     # Generic with two parameters
```

### Effect Rows

```
![IO]                                # Single effect
![IO, Console]                       # Multiple effects
![IO, Console, r]                    # With row variable
![DB<Idle -> Active>]                # With protocol state transition
![DB<* -> Open>]                     # Ground state to Open
![Register<Scanning>]                # Single state (same from and to)
```

## Array vs ArrayRef, Hash vs HashRef

`Array[T]` and `Hash[K, V]` are **list types**, representing list-producing expressions. `ArrayRef[T]` and `HashRef[K, V]` are **scalar reference types**. They are not interchangeable:

```perl
# ArrayRef: a scalar reference to an array
my $items :sig(ArrayRef[Int]) = [1, 2, 3];

# Array: the list type (used for list-context return types)
sub get_names :sig(() -> Array[Str]) () { ("Alice", "Bob") }
```

## CodeRef Desugaring

`CodeRef[A -> B]` is syntactic sugar for a function type:

```
CodeRef[Int -> Str]    ===    (Int) -> Str
CodeRef[Int, Str -> Bool]    ===    (Int, Str) -> Bool
```

Effects can be included inside the brackets:

```
CodeRef[Int -> Str ![IO]]    ===    (Int) -> Str ![IO]
```

## Maybe Desugaring

`Maybe[T]` desugars to `T | Undef`:

```
Maybe[Str]    ===    Str | Undef
Maybe[Int]    ===    Int | Undef
```

## Parser Caching

Both `parse($expr)` for type expressions and `parse_annotation($input)` for `:sig()` content are cached using an LRU cache with a 1000-entry limit. On overflow, the oldest 25% of entries (by access epoch) are evicted, preserving frequently used entries. The cache is global and shared across all parse calls.

## Safety Limits

- **Maximum nesting depth**: 64 levels of recursive type expression nesting.
- **Maximum input length**: 10,000 characters per type expression or annotation string.

Exceeding either limit raises a parse error.
