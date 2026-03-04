package Typist::Static::Unify;
use v5.40;

our $VERSION = '0.01';

use Typist::Subtype;
use Typist::Type::Atom;

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
        # Skip binding to Any — carries no information (gradual typing)
        return $bindings if $actual->is_atom && $actual->name eq 'Any';
        # Occurs check: reject infinite types (e.g. T = ArrayRef[T])
        # Only applies to compound types — Var-to-Var binding (T = T) is harmless.
        return undef if !$actual->is_var && grep { $_ eq $name } $actual->free_vars;
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
        # HKT: formal has a Var base (e.g., F[A]) → bind the base variable
        if ($formal->has_var_base) {
            my $actual_base = $actual->base;
            # Normalize: wrap string base as Atom for consistent binding
            my $base_type = ref $actual_base && $actual_base->isa('Typist::Type')
                ? $actual_base
                : Typist::Type::Atom->new($actual_base);
            $bindings = $class->unify($formal->base, $base_type, $bindings, %opts);
            return undef unless $bindings;
        } else {
            return undef unless "${\$formal->base}" eq "${\$actual->base}";
        }
        my @fp = $formal->params;
        my @ap = $actual->params;
        return undef unless @fp == @ap;
        for my $i (0 .. $#fp) {
            $bindings = $class->unify($fp[$i], $ap[$i], $bindings, registry => $registry);
            return undef unless $bindings;
        }
        return $bindings;
    }

    # ── Param vs Struct (or vice versa) ───────
    # Attribute::resolve_struct_params converts Param → Struct in the registry,
    # while CallChecker re-parses from strings back to Param.  Bridge the gap
    # by treating a Struct with type_args as equivalent to a Param for unification.
    if ($formal->is_param && $actual->is_struct) {
        my @ta = $actual->type_args;
        if (@ta) {
            return undef unless "${\$formal->base}" eq $actual->name;
            my @fp = $formal->params;
            return undef unless @fp == @ta;
            for my $i (0 .. $#fp) {
                $bindings = $class->unify($fp[$i], $ta[$i], $bindings, registry => $registry);
                return undef unless $bindings;
            }
            return $bindings;
        }
    }
    if ($formal->is_struct && $actual->is_param) {
        my @ta = $formal->type_args;
        if (@ta) {
            return undef unless $formal->name eq "${\$actual->base}";
            my @ap = $actual->params;
            return undef unless @ta == @ap;
            for my $i (0 .. $#ta) {
                $bindings = $class->unify($ta[$i], $ap[$i], $bindings, registry => $registry);
                return undef unless $bindings;
            }
            return $bindings;
        }
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
    if ($formal->is_record && $actual->is_record) {
        my %freq = $formal->required_fields;
        my %areq = $actual->required_fields;
        for my $key (sort keys %freq) {
            my $atype = $areq{$key} // next;
            $bindings = $class->unify($freq{$key}, $atype, $bindings, registry => $registry);
            return undef unless $bindings;
        }
        return $bindings;
    }

    # ── Quantified types ──────────────────────
    # formal is Quantified: freshen vars and unify body
    if ($formal->is_quantified && !$actual->is_quantified) {
        my $body = $formal->body;
        # Instantiate: just unify the body (vars become free for binding)
        return $class->unify($body, $actual, $bindings, %opts);
    }
    # actual is Quantified: instantiate and unify body
    if (!$formal->is_quantified && $actual->is_quantified) {
        return $class->unify($formal, $actual->body, $bindings, %opts);
    }
    # Both Quantified: match vars count and unify bodies
    if ($formal->is_quantified && $actual->is_quantified) {
        my @fv = $formal->vars;
        my @av = $actual->vars;
        return undef unless @fv == @av;
        # Rename actual's vars to formal's vars for body comparison
        my %rename;
        for my $i (0 .. $#fv) {
            require Typist::Type::Var;
            $rename{$av[$i]{name}} = Typist::Type::Var->new($fv[$i]{name});
        }
        my $actual_body = $actual->body->substitute(\%rename);
        return $class->unify($formal->body, $actual_body, $bindings, %opts);
    }

    # ── Both Union → delegate to subtype ──────
    # Union types are too complex for structural unification;
    # fall through to the subtype check below.

    # ── Fallback: subtype compatibility ───────
    # If the formal type has no free variables and actual is a subtype, succeed.
    if (!scalar($formal->free_vars)) {
        return Typist::Subtype->is_subtype($actual, $formal, registry => $registry) ? $bindings : undef;
    }

    # Structural mismatch with unresolved vars -- cannot unify
    undef;
}

# ── Binding Collection ──────────────────────────
#
# Recursively collect type variable bindings by structural matching.
# Returns 1 on success, 0 on conflict. Populates $bindings hashref.

sub collect_bindings ($class, $formal, $actual, $bindings) {
    if ($formal->is_var) {
        my $name = $formal->name;
        if (exists $bindings->{$name}) {
            return $bindings->{$name}->equals($actual) ? 1 : 0;
        }
        # Skip binding to Any — it carries no information (gradual typing)
        # and would prevent Pass 2 from discovering a concrete type.
        return 1 if $actual->is_atom && $actual->name eq 'Any';
        # Occurs check: reject infinite types (e.g. T = ArrayRef[T])
        # Only applies to compound types — Var-to-Var binding (T = T) is harmless.
        return 0 if !$actual->is_var && grep { $_ eq $name } $actual->free_vars;
        $bindings->{$name} = $actual;
        return 1;
    }
    if ($formal->is_func && $actual->is_func) {
        my @fp = $formal->params;
        my @ap = $actual->params;
        return 0 unless @fp == @ap;
        for my $i (0 .. $#fp) {
            $class->collect_bindings($fp[$i], $ap[$i], $bindings) or return 0;
        }
        return $class->collect_bindings($formal->returns, $actual->returns, $bindings);
    }
    if ($formal->is_param && $actual->is_param) {
        # HKT: formal has a Var base (e.g., F[A]) → bind the base variable
        if ($formal->has_var_base) {
            my $actual_base = $actual->base;
            my $base_type = ref $actual_base && $actual_base->isa('Typist::Type')
                ? $actual_base
                : Typist::Type::Atom->new($actual_base);
            $class->collect_bindings($formal->base, $base_type, $bindings) or return 0;
        } else {
            return 0 unless "${\$formal->base}" eq "${\$actual->base}";
        }
        my @fp = $formal->params;
        my @ap = $actual->params;
        return 0 unless @fp == @ap;
        for my $i (0 .. $#fp) {
            $class->collect_bindings($fp[$i], $ap[$i], $bindings) or return 0;
        }
        return 1;
    }
    # ── Param vs Struct (or vice versa) ───────
    if ($formal->is_param && $actual->is_struct) {
        my @ta = $actual->type_args;
        if (@ta) {
            return 0 unless "${\$formal->base}" eq $actual->name;
            my @fp = $formal->params;
            return 0 unless @fp == @ta;
            for my $i (0 .. $#fp) {
                $class->collect_bindings($fp[$i], $ta[$i], $bindings) or return 0;
            }
            return 1;
        }
    }
    if ($formal->is_struct && $actual->is_param) {
        my @ta = $formal->type_args;
        if (@ta) {
            return 0 unless $formal->name eq "${\$actual->base}";
            my @ap = $actual->params;
            return 0 unless @ta == @ap;
            for my $i (0 .. $#ta) {
                $class->collect_bindings($ta[$i], $ap[$i], $bindings) or return 0;
            }
            return 1;
        }
    }
    # ── Quantified types ──────────────────────
    # Both Quantified: match vars count, rename, recurse on bodies
    if ($formal->is_quantified && $actual->is_quantified) {
        my @fv = $formal->vars;
        my @av = $actual->vars;
        return 0 unless @fv == @av;
        my %rename;
        for my $i (0 .. $#fv) {
            require Typist::Type::Var;
            $rename{$av[$i]{name}} = Typist::Type::Var->new($fv[$i]{name});
        }
        my $actual_body = $actual->body->substitute(\%rename);
        return $class->collect_bindings($formal->body, $actual_body, $bindings);
    }
    # formal only Quantified: unwrap body
    if ($formal->is_quantified && !$actual->is_quantified) {
        return $class->collect_bindings($formal->body, $actual, $bindings);
    }
    # actual only Quantified: unwrap body
    if (!$formal->is_quantified && $actual->is_quantified) {
        return $class->collect_bindings($formal, $actual->body, $bindings);
    }

    # Non-variable leaf: must be structurally equal
    $formal->equals($actual) ? 1 : 0;
}

# ── Substitution ────────────────────────────────
#
# Replace type variables with their bindings.
# Delegates to each type node's built-in substitute method.

sub substitute ($class, $type, $bindings) {
    $type->substitute($bindings);
}

1;

=head1 NAME

Typist::Static::Unify - Structural type unification with variable binding extraction

=head1 DESCRIPTION

Pairs formal (annotated) types against actual (inferred) types, extracting
type-variable bindings. Handles atoms, parametric types, functions, records,
quantified types, HKT variable bases, and union fallback via subtype checking.

=head2 unify

    my $bindings = Typist::Static::Unify->unify($formal, $actual);
    my $bindings = Typist::Static::Unify->unify($formal, $actual, \%existing, registry => $reg);

Structurally unifies C<$formal> against C<$actual>, returning a hashref of
type-variable bindings on success or C<undef> on mismatch. When a variable is
seen more than once, existing bindings are widened via
L<Typist::Subtype/common_super>. Accepts an optional C<registry> for alias
resolution in LSP context.

=head2 collect_bindings

    my $ok = Typist::Static::Unify->collect_bindings($formal, $actual, \%bindings);

Recursively collects type-variable bindings by strict structural matching.
Returns C<1> on success and C<0> on conflict. Unlike C<unify>, conflicting
bindings for the same variable are rejected rather than widened. Populates the
provided C<%bindings> hashref in place.

=head2 substitute

    my $resolved = Typist::Static::Unify->substitute($type, \%bindings);

Replaces type variables in C<$type> with their bound values from
C<%bindings>. Delegates to the type node's own C<substitute> method.

=cut
