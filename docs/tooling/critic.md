# Perl::Critic Policies

Typist ships four Perl::Critic policies that check for common issues in Typist-annotated code. These complement the static analyzer by catching stylistic and structural problems that are better expressed as lint rules.

All policies use the `typist` theme.

---

## Available Policies

### Typist::AnnotationStyle

**Severity**: Low (2)

Warns when public subroutines (those not starting with `_`) lack a `:sig()` annotation. In a Typist codebase, every public function should carry a type signature for static analysis and documentation.

```typist
# Violation: public sub without :sig()
sub calculate_total ($items) { ... }

# Clean: has :sig()
sub calculate_total :sig((ArrayRef[LineItem]) -> Price) ($items) { ... }

# Clean: private sub (underscore prefix) -- not checked
sub _validate ($input) { ... }
```

Configuration:

```ini
[Typist::AnnotationStyle]
severity = 4
```

---

### Typist::EffectCompleteness

**Severity**: Medium (3)

Warns when a function calls effect operations (qualified calls matching `CapitalizedPkg::operation`) without declaring effects in its `:sig()` annotation via the `!` syntax.

```typist
# Violation: calls Logger::log but doesn't declare ![Logger]
sub process :sig((Str) -> Void) ($msg) {
    Logger::log("Processing: $msg");
}

# Clean: effects declared
sub process :sig((Str) -> Void ![Logger]) ($msg) {
    Logger::log("Processing: $msg");
}
```

The policy uses a heuristic pattern (`CapitalizedPkg::lowercase_method`) to detect effect operation calls. Known non-effect namespaces are excluded (Typist, Perl, PPI, Test, CORE, Carp, File, IO, JSON, DBI, etc.).

Configuration:

```ini
[Typist::EffectCompleteness]
severity = 3
```

---

### Typist::ExhaustivenessCheck

**Severity**: Low (2)

Warns when a `match` expression does not cover all variants and has no `_` fallback arm. A `match` without a fallback will `die` at runtime if an unmatched variant is encountered.

```typist
BEGIN {
    datatype Shape => (
        Circle    => '(Int)',
        Rectangle => '(Int, Int)',
        Triangle  => '(Int, Int, Int)',
    );
}

# Violation: missing Triangle arm, no _ fallback
my $area = match $shape,
    Circle    => sub ($r) { 3.14 * $r * $r },
    Rectangle => sub ($w, $h) { $w * $h };

# Clean: all variants covered
my $area = match $shape,
    Circle    => sub ($r) { 3.14 * $r * $r },
    Rectangle => sub ($w, $h) { $w * $h },
    Triangle  => sub ($a, $b, $c) { ... };

# Clean: has _ fallback
my $area = match $shape,
    Circle => sub ($r) { 3.14 * $r * $r },
    _      => sub { 0 };
```

Configuration:

```ini
[Typist::ExhaustivenessCheck]
severity = 4
```

---

### Typist::TypeCheck

**Severity**: Low (2)

Runs the full Typist static analyzer (`Typist::Static::Analyzer`) as a Perl::Critic policy. This integrates all of Typist's type checking, effect checking, and protocol checking into the Perl::Critic framework.

Detected issues and their severity mapping:

| Diagnostic kind | Critic severity |
|----------------|:---------------:|
| CycleError | 5 (highest) |
| TypeError | 4 (high) |
| TypeMismatch | 4 (high) |
| ResolveError | 4 (high) |
| UndeclaredTypeVar | 3 (medium) |
| UnknownType | 2 (low) |

Configuration:

```ini
[Typist::TypeCheck]
severity = 2
```

---

## Running the Policies

### Via mise

```sh
mise run test:critic    # Run all Perl::Critic tests
```

### Via perlcritic directly

```sh
perlcritic --theme typist lib/MyApp/Order.pm
```

### In a .perlcriticrc

```ini
theme = typist

[Typist::AnnotationStyle]
severity = 4

[Typist::EffectCompleteness]
severity = 3

[Typist::ExhaustivenessCheck]
severity = 4

[Typist::TypeCheck]
severity = 2
```

---

## Policy Locations

The policies are installed at:

```
lib/Perl/Critic/Policy/Typist/AnnotationStyle.pm
lib/Perl/Critic/Policy/Typist/EffectCompleteness.pm
lib/Perl/Critic/Policy/Typist/ExhaustivenessCheck.pm
lib/Perl/Critic/Policy/Typist/TypeCheck.pm
```

Tests are in:

```
t/critic/00_policy.t
t/critic/01_annotation_style.t
t/critic/02_effect_completeness.t
t/critic/03_exhaustiveness.t
```

---

## Relationship to typist-check

The `Typist::TypeCheck` Perl::Critic policy runs the same analyzer as `typist-check`, but within the Perl::Critic framework. Use `typist-check` for dedicated type checking in CI; use the Perl::Critic policies when you want to integrate type checking into an existing Perl::Critic workflow or combine it with other Perl::Critic policies.

The other three policies (AnnotationStyle, EffectCompleteness, ExhaustivenessCheck) are lightweight PPI-based checks that do not invoke the full analyzer. They run quickly and check for structural patterns rather than deep type correctness.
