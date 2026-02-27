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
    if ($sub->is_struct && $super->is_struct) {
        my %sf = $sub->fields;
        my %pf = $super->fields;
        return all {
            exists $sf{$_} && _check($sf{$_}, $pf{$_})
        } keys %pf;
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
