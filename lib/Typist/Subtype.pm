package Typist::Subtype;
use v5.40;

use Typist::Type::Atom;
use List::Util 'any', 'all';

# Primitive hierarchy: Any > Num > Int > Bool, Any > Str, Any > Undef, Any > Void
my %PARENT = (
    Bool  => 'Int',
    Int   => 'Num',
    Num   => 'Any',
    Str   => 'Any',
    Undef => 'Any',
    Void  => 'Any',
);

# ── Public API ────────────────────────────────────

# Is $sub a subtype of $super?
sub is_subtype ($class, $sub, $super) {
    _check($sub, $super);
}

# ── Internal ──────────────────────────────────────

sub _check ($sub, $super) {
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
        my $r = Typist::Registry->lookup_type($sub->alias_name);
        return _check($r, $super) if $r;
    }
    if ($super->is_alias) {
        my $r = Typist::Registry->lookup_type($super->alias_name);
        return _check($sub, $r) if $r;
    }

    # ── Union rules ──────────────────────────────
    # T|U <: S  iff  T <: S AND U <: S
    if ($sub->is_union) {
        return all { _check($_, $super) } $sub->members;
    }
    # S <: T|U  iff  S <: T OR S <: U
    if ($super->is_union) {
        return any { _check($sub, $_) } $super->members;
    }

    # ── Intersection rules ───────────────────────
    # T&U <: S  iff  T <: S OR U <: S
    if ($sub->is_intersection) {
        return any { _check($_, $super) } $sub->members;
    }
    # S <: T&U  iff  S <: T AND S <: U
    if ($super->is_intersection) {
        return all { _check($sub, $_) } $super->members;
    }

    # ── Newtype (nominal identity) ────────────────
    # Newtype only subtypes itself (same name) — no structural compatibility
    if ($sub->is_newtype || $super->is_newtype) {
        return $sub->is_newtype && $super->is_newtype
            && $sub->name eq $super->name;
    }

    # ── Literal types ─────────────────────────────
    # Literal <: Literal  only when same value (identity, already handled above)
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
        return all { _check($sp[$_], $pp[$_]) } 0 .. $#sp;
    }

    # ── Function types (contravariant params, covariant return) ──
    if ($sub->is_func && $super->is_func) {
        my @sp = $sub->params;
        my @pp = $super->params;
        return 0 unless @sp == @pp;
        # Contravariant in parameter types
        my $params_ok = all { _check($pp[$_], $sp[$_]) } 0 .. $#sp;
        # Covariant in return type
        return $params_ok && _check($sub->returns, $super->returns);
    }

    # ── Struct width subtyping ───────────────────
    # { a: T, b: U } <: { a: T }  (more fields <: fewer fields)
    # Optional field rules:
    #   super required → sub must have (required or optional)
    #   super optional → sub may have or omit; if present, must be type-compatible
    if ($sub->is_struct && $super->is_struct) {
        my %sub_req = $sub->required_fields;
        my %sub_opt = $sub->optional_fields;
        my %sup_req = $super->required_fields;
        my %sup_opt = $super->optional_fields;

        # Every required field in super must be required in sub and type-compatible
        for my $key (keys %sup_req) {
            return 0 unless exists $sub_req{$key};
            return 0 unless _check($sub_req{$key}, $sup_req{$key});
        }
        # Optional fields in super: if present in sub, must be type-compatible
        for my $key (keys %sup_opt) {
            if (exists $sub_req{$key}) {
                return 0 unless _check($sub_req{$key}, $sup_opt{$key});
            } elsif (exists $sub_opt{$key}) {
                return 0 unless _check($sub_opt{$key}, $sup_opt{$key});
            }
            # Not present in sub at all — that's fine for optional
        }
        return 1;
    }

    # ── Eff types — delegate to inner Row ────────
    if ($sub->is_eff && $super->is_eff) {
        return _check($sub->row, $super->row);
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
