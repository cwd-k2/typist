package Typist::Static::Unify;
use v5.40;

use Typist::Subtype;

# ── Type-Based Unification ──────────────────────
#
# Structural unification of formal (annotated) types against actual
# (inferred) types, extracting type-variable bindings.
#
# unify($formal, $actual, $bindings?, %opts) → { VarName => Type } | undef
#
#   Var('T')  vs Atom('Int')                → { T => Int }
#   Param('ArrayRef', [Var('T')])
#       vs Param('ArrayRef', [Atom('Int')]) → { T => Int }
#   Atom('Int')  vs Atom('Str')             → undef (mismatch)
#   Atom('Int')  vs Atom('Int')             → {} (match, no bindings)
#
# Optional: registry => $instance for alias resolution in LSP context.

sub unify ($class, $formal, $actual, $bindings = +{}, %opts) {
    my $registry = $opts{registry};

    # ── Type variable → bind or widen ──────────
    if ($formal->is_var) {
        my $name = $formal->name;
        if (exists $bindings->{$name}) {
            my $widened = Typist::Subtype->common_super($bindings->{$name}, $actual);
            return +{ %$bindings, $name => $widened };
        }
        return +{ %$bindings, $name => $actual };
    }

    # ── Both Atom → name equality ─────────────
    if ($formal->is_atom && $actual->is_atom) {
        return $formal->name eq $actual->name ? $bindings : undef;
    }

    # ── Atom formal vs Literal actual ─────────
    # Literal(42, Int) should unify with Atom(Int) via subtype chain
    if ($formal->is_atom && $actual->is_literal) {
        return Typist::Subtype->is_subtype($actual, $formal, registry => $registry) ? $bindings : undef;
    }

    # ── Both Param → base match + recursive ───
    if ($formal->is_param && $actual->is_param) {
        return undef unless $formal->base eq $actual->base;
        my @fp = $formal->params;
        my @ap = $actual->params;
        return undef unless @fp == @ap;
        for my $i (0 .. $#fp) {
            $bindings = $class->unify($fp[$i], $ap[$i], $bindings, registry => $registry);
            return undef unless $bindings;
        }
        return $bindings;
    }

    # ── Both Func → params + return ───────────
    if ($formal->is_func && $actual->is_func) {
        my @fp = $formal->params;
        my @ap = $actual->params;
        return undef unless @fp == @ap;
        for my $i (0 .. $#fp) {
            $bindings = $class->unify($fp[$i], $ap[$i], $bindings, registry => $registry);
            return undef unless $bindings;
        }
        $bindings = $class->unify($formal->returns, $actual->returns, $bindings, registry => $registry);
        return $bindings;
    }

    # ── Both Struct → field-wise ──────────────
    if ($formal->is_struct && $actual->is_struct) {
        my %freq = $formal->required_fields;
        my %areq = $actual->required_fields;
        for my $key (sort keys %freq) {
            my $atype = $areq{$key} // next;
            $bindings = $class->unify($freq{$key}, $atype, $bindings, registry => $registry);
            return undef unless $bindings;
        }
        return $bindings;
    }

    # ── Both Union → delegate to subtype ──────
    # Union types are too complex for structural unification;
    # fall through to the subtype check below.

    # ── Fallback: subtype compatibility ───────
    # If the formal type has no free variables and actual is a subtype, succeed.
    if (!scalar($formal->free_vars)) {
        return Typist::Subtype->is_subtype($actual, $formal, registry => $registry) ? $bindings : undef;
    }

    # Structural mismatch with unresolved vars → cannot unify
    undef;
}

# ── Substitution ────────────────────────────────
#
# Replace type variables with their bindings.
# Delegates to each type node's built-in substitute method.

sub substitute ($class, $type, $bindings) {
    $type->substitute($bindings);
}

1;
