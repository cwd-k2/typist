package Typist::Subtype;
use v5.40;

our $VERSION = '0.01';

use Typist::Type::Atom;
use Typist::Type::Var;
use List::Util 'any', 'all';

# Primitive hierarchy: Any > Num > Double > Int > Bool, Any > Str, Any > Undef, Any > Void
my %PARENT = (
    Bool   => 'Int',
    Int    => 'Double',
    Double => 'Num',
    Num    => 'Any',
    Str    => 'Any',
    Undef  => 'Any',
    Void   => 'Any',
);

# Atom ordering for common supertype (LUB) computation
my %ATOM_ORDER = (Bool => 0, Int => 1, Double => 2, Num => 3, Str => 4, Any => 5);

# ── Public API ────────────────────────────────────

# Is $sub a subtype of $super?
# Optional: registry => $instance for alias resolution in LSP context.
sub is_subtype ($class, $sub, $super, %opts) {
    _check($sub, $super, $opts{registry});
}

# Least upper bound of two types in the atom lattice.
sub common_super ($class, $a, $b) {
    return $a if $a->equals($b);

    # Promote literals to their base Atom for LUB computation
    my $a_eff = $a->is_literal ? Typist::Type::Atom->new($a->base_type) : $a;
    my $b_eff = $b->is_literal ? Typist::Type::Atom->new($b->base_type) : $b;
    return $a_eff if $a_eff->equals($b_eff);

    if ($a_eff->is_atom && $b_eff->is_atom) {
        my $oa = $ATOM_ORDER{$a_eff->name} // 4;
        my $ob = $ATOM_ORDER{$b_eff->name} // 4;

        if (exists $ATOM_ORDER{$a_eff->name} && exists $ATOM_ORDER{$b_eff->name}) {
            if ($a_eff->name ne 'Str' && $b_eff->name ne 'Str') {
                return $oa > $ob ? $a_eff : $b_eff;
            }
        }
    }

    # Struct LUB: intersect field names, LUB each field's type
    if ($a_eff->is_record && $b_eff->is_record) {
        require Typist::Type::Record;
        my %a_req = $a_eff->required_fields;
        my %b_req = $b_eff->required_fields;
        my %a_opt = $a_eff->optional_fields;
        my %b_opt = $b_eff->optional_fields;

        my %result;
        # Common required fields: LUB of each field type
        for my $key (keys %a_req) {
            if (exists $b_req{$key}) {
                $result{$key} = $class->common_super($a_req{$key}, $b_req{$key});
            } elsif (exists $b_opt{$key}) {
                # Required in A, optional in B → optional in LUB
                $result{"${key}?"} = $class->common_super($a_req{$key}, $b_opt{$key});
            } else {
                # Only in A → optional in LUB
                $result{"${key}?"} = $a_req{$key};
            }
        }
        # B-only required fields → optional in LUB
        for my $key (keys %b_req) {
            next if exists $a_req{$key};
            if (exists $a_opt{$key}) {
                $result{"${key}?"} = $class->common_super($a_opt{$key}, $b_req{$key});
            } else {
                $result{"${key}?"} = $b_req{$key};
            }
        }
        # Common optional fields
        for my $key (keys %a_opt) {
            next if exists $result{$key} || exists $result{"${key}?"};
            if (exists $b_opt{$key}) {
                $result{"${key}?"} = $class->common_super($a_opt{$key}, $b_opt{$key});
            } else {
                $result{"${key}?"} = $a_opt{$key};
            }
        }
        for my $key (keys %b_opt) {
            next if exists $result{$key} || exists $result{"${key}?"};
            $result{"${key}?"} = $b_opt{$key};
        }
        return Typist::Type::Record->new(%result) if %result;
    }

    Typist::Type::Atom->new('Any');
}

# ── Internal ──────────────────────────────────────

# $registry is optional: when provided, used for alias resolution
# instead of the singleton Typist::Registry.
sub _check ($sub, $super, $registry = undef) {
    # Identity — T <: T
    return 1 if $sub->equals($super);

    # Everything <: Any
    return 1 if $super->is_atom && $super->name eq 'Any';

    # Never <: T for all T (bottom type)
    return 1 if $sub->is_atom && $sub->name eq 'Never';

    # Void <: nothing (except Any, handled above)
    return 0 if $sub->is_atom && $sub->name eq 'Void';

    # Resolve aliases before comparison
    if ($sub->is_alias) {
        my $r = $registry
            ? $registry->lookup_type($sub->alias_name)
            : Typist::Registry->lookup_type($sub->alias_name);
        return _check($r, $super, $registry) if $r;
    }
    if ($super->is_alias) {
        my $r = $registry
            ? $registry->lookup_type($super->alias_name)
            : Typist::Registry->lookup_type($super->alias_name);
        return _check($sub, $r, $registry) if $r;
    }

    # ── Union rules ──────────────────────────────
    # T|U <: S  iff  T <: S AND U <: S
    if ($sub->is_union) {
        return all { _check($_, $super, $registry) } $sub->members;
    }
    # S <: T|U  iff  S <: T OR S <: U
    if ($super->is_union) {
        return any { _check($sub, $_, $registry) } $super->members;
    }

    # ── Intersection rules ───────────────────────
    # T&U <: S  iff  T <: S OR U <: S
    if ($sub->is_intersection) {
        return any { _check($_, $super, $registry) } $sub->members;
    }
    # S <: T&U  iff  S <: T AND S <: U
    if ($super->is_intersection) {
        return all { _check($sub, $_, $registry) } $super->members;
    }

    # ── Newtype (nominal identity) ────────────────
    # Newtype only subtypes itself (same name) — no structural compatibility
    if ($sub->is_newtype || $super->is_newtype) {
        return $sub->is_newtype && $super->is_newtype
            && $sub->name eq $super->name;
    }

    # ── Data type (nominal + covariant type args) ──
    if ($sub->is_data || $super->is_data) {
        return 0 unless $sub->is_data && $super->is_data
            && $sub->name eq $super->name;
        my @sa = $sub->type_args;
        my @oa = $super->type_args;
        return 1 if !@sa && !@oa;
        return 0 if @sa != @oa;
        return all { _check($sa[$_], $oa[$_], $registry) } 0 .. $#sa;
    }

    # ── Literal types ─────────────────────────────
    # Literal(v1, B1) <: Literal(v2, B2) iff same value AND base subtype
    if ($sub->is_literal && $super->is_literal) {
        return "${\$sub->value}" eq "${\$super->value}"
            && _atom_subtype($sub->base_type, $super->base_type);
    }
    # Literal(v) <: BaseType  when base_type hierarchy holds
    if ($sub->is_literal && $super->is_atom) {
        return _atom_subtype($sub->base_type, $super->name);
    }
    # T </: Literal(v)  unless T is also Literal(v) (already handled by equals)
    return 0 if $super->is_literal && !$sub->is_literal;

    # ── Atom primitives ──────────────────────────
    if ($sub->is_atom && $super->is_atom) {
        return _atom_subtype($sub->name, $super->name);
    }

    # ── Parameterized types ──────────────────────
    if ($sub->is_param && $super->is_param) {
        return 0 unless $sub->base eq $super->base;
        my @sp = $sub->params;
        my @pp = $super->params;
        return 1 unless @pp;  # raw base matches raw base
        return 0 unless @sp == @pp;
        # Covariant: ArrayRef[T] <: ArrayRef[U] iff T <: U
        return all { _check($sp[$_], $pp[$_], $registry) } 0 .. $#sp;
    }

    # ── Function types (contravariant params, covariant return, covariant effects) ──
    if ($sub->is_func && $super->is_func) {
        my @sp = $sub->params;
        my @pp = $super->params;
        return 0 unless @sp == @pp;
        # Contravariant in parameter types
        return 0 unless all { _check($pp[$_], $sp[$_], $registry) } 0 .. $#sp;
        # Covariant in return type
        return 0 unless _check($sub->returns, $super->returns, $registry);
        # Covariant in effects
        my $se = $sub->effects;
        my $pe = $super->effects;
        return 1 if !$se && !$pe;     # both pure
        return 0 if !$se != !$pe;     # one pure, one effectful
        return _check($se, $pe, $registry);      # delegate to Row subtyping
    }

    # ── Nominal struct subtyping ─────────────────
    # Struct(A) <: Struct(B) only if same name (nominal identity)
    if ($sub->is_struct && $super->is_struct) {
        return $sub->name eq $super->name;
    }
    # Struct <: Record (structural compatibility via inner record)
    if ($sub->is_struct && $super->is_record) {
        return _check($sub->record, $super, $registry);
    }
    # Record </: Struct (nominal barrier)
    return 0 if $sub->is_record && $super->is_struct;

    # ── Record width subtyping ───────────────────
    # { a: T, b: U } <: { a: T }  (more fields <: fewer fields)
    # Optional field rules:
    #   super required → sub must have (required or optional)
    #   super optional → sub may have or omit; if present, must be type-compatible
    if ($sub->is_record && $super->is_record) {
        my %sub_req = $sub->required_fields;
        my %sub_opt = $sub->optional_fields;
        my %sup_req = $super->required_fields;
        my %sup_opt = $super->optional_fields;

        # Every required field in super must be required in sub and type-compatible
        for my $key (keys %sup_req) {
            return 0 unless exists $sub_req{$key};
            return 0 unless _check($sub_req{$key}, $sup_req{$key}, $registry);
        }
        # Optional fields in super: if present in sub, must be type-compatible
        for my $key (keys %sup_opt) {
            if (exists $sub_req{$key}) {
                return 0 unless _check($sub_req{$key}, $sup_opt{$key}, $registry);
            } elsif (exists $sub_opt{$key}) {
                return 0 unless _check($sub_opt{$key}, $sup_opt{$key}, $registry);
            }
            # Not present in sub at all — that's fine for optional
        }
        return 1;
    }

    # ── Quantified types (forall) ────────────────
    # forall A. A -> A  <:  Int -> Int  (instantiation)
    if ($sub->is_quantified && !$super->is_quantified) {
        # Try instantiation: substitute vars with types inferred from super
        my %bindings;
        for my $v ($sub->vars) {
            # Bind each quantified var to Any for a permissive check,
            # then verify with the concrete super type.
            $bindings{$v->{name}} = Typist::Type::Atom->new('Any');
        }
        # Try to find a valid instantiation by matching body against super
        my $inst = _instantiate_check($sub, $super, $registry);
        return $inst if defined $inst;
        # Fallback: instantiate with Any and check
        my $body = $sub->body->substitute(\%bindings);
        return _check($body, $super, $registry);
    }
    # Concrete ≮: forall (a mono type cannot satisfy a universally quantified type)
    # Exception: gradual types containing Any are compatible (partial inference)
    if (!$sub->is_quantified && $super->is_quantified) {
        return 1 if _contains_any($sub);
        return 0;
    }
    # forall <: forall (subsumption: rename and compare bodies)
    if ($sub->is_quantified && $super->is_quantified) {
        my @sv = $sub->vars;
        my @ov = $super->vars;
        return 0 unless @sv == @ov;
        # Check bounds compatibility
        for my $i (0 .. $#sv) {
            my $sb = $sv[$i]{bound};
            my $ob = $ov[$i]{bound};
            return 0 if !$sb != !$ob;
            if ($sb && $ob) {
                return 0 unless _check($ob, $sb, $registry);  # contravariant bounds
            }
        }
        # Rename super's vars to sub's vars for body comparison
        my %rename;
        for my $i (0 .. $#sv) {
            $rename{$ov[$i]{name}} = Typist::Type::Var->new($sv[$i]{name});
        }
        my $super_body = $super->body->substitute(\%rename);
        return _check($sub->body, $super_body, $registry);
    }

    # ── Eff types — delegate to inner Row ────────
    if ($sub->is_eff && $super->is_eff) {
        return _check($sub->row, $super->row, $registry);
    }

    # ── Row subtyping — label set inclusion ───────
    # Row(A,B,C) <: Row(A,B) iff super's labels ⊆ sub's labels
    if ($sub->is_row && $super->is_row) {
        my %sub_labels = map { $_ => 1 } $sub->labels;
        for my $label ($super->labels) {
            return 0 unless $sub_labels{$label};
        }
        return 1;
    }

    0;
}

# Try to instantiate a Quantified type to match a concrete super type.
# Uses structural matching to infer bindings for quantified variables.
sub _instantiate_check ($quant, $target, $registry) {
    my %bindings;
    my $body = $quant->body;

    # Simple case: both are Func — match params/return structurally
    if ($body->is_func && $target->is_func) {
        my @bp = $body->params;
        my @tp = $target->params;
        return undef unless @bp == @tp;

        require Typist::Static::Unify;
        for my $i (0 .. $#bp) {
            Typist::Static::Unify->collect_bindings($bp[$i], $tp[$i], \%bindings) or return undef;
        }
        Typist::Static::Unify->collect_bindings($body->returns, $target->returns, \%bindings) or return undef;

        # Verify bounds
        for my $v ($quant->vars) {
            my $actual = $bindings{$v->{name}} // next;
            if ($v->{bound}) {
                return 0 unless _check($actual, $v->{bound}, $registry);
            }
        }

        my $instantiated = $body->substitute(\%bindings);
        return _check($instantiated, $target, $registry) ? 1 : 0;
    }

    undef;
}

# Check whether a type transitively contains Any (gradual typing marker).
sub _contains_any ($type) {
    return 1 if $type->is_atom && $type->name eq 'Any';
    if ($type->is_func) {
        return 1 if any { _contains_any($_) } $type->params;
        return 1 if _contains_any($type->returns);
    }
    if ($type->is_param) {
        return 1 if any { _contains_any($_) } $type->params;
    }
    if ($type->is_union) {
        return 1 if any { _contains_any($_) } $type->members;
    }
    0;
}

sub _atom_subtype ($sub_name, $super_name) {
    return 1 if $sub_name eq $super_name;

    my $current = $sub_name;
    while (my $parent = $PARENT{$current}) {
        return 1 if $parent eq $super_name;
        $current = $parent;
    }
    0;
}

1;

=head1 NAME

Typist::Subtype - Structural subtype relation and least upper bound

=head1 SYNOPSIS

    use Typist::Subtype;

    my $ok  = Typist::Subtype->is_subtype($sub, $super);
    my $lub = Typist::Subtype->common_super($a, $b);

=head1 DESCRIPTION

Implements the subtype relation for Typist's type system. The relation
covers atom primitives (C<Bool E<lt>: Int E<lt>: Double E<lt>: Num E<lt>: Any>),
unions, intersections, parametric types (covariant), function types
(contravariant params, covariant return), records (width subtyping),
structs (nominal identity), newtypes (nominal), data types (covariant
type args), literals, quantified types (forall), rows, and effects.

C<common_super> computes the least upper bound (LUB) in the atom
lattice and performs field-wise LUB for record types.

=head1 METHODS

=head2 is_subtype

    my $bool = Typist::Subtype->is_subtype($sub, $super, %opts);

Returns true if C<$sub> is a subtype of C<$super>. Accepts an optional
C<registry> parameter for alias resolution in LSP contexts.

=head2 common_super

    my $lub = Typist::Subtype->common_super($a, $b);

Returns the least upper bound of two types. Falls back to C<Any> when
no better common type exists.

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Static::Unify>

=cut
