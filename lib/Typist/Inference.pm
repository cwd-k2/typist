package Typist::Inference;
use v5.40;

use Scalar::Util 'looks_like_number', 'reftype';
use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Struct;

# ── Value Inference ───────────────────────────────

# Infer the most specific type from a runtime value.
sub infer_value ($class, $value) {
    return Typist::Type::Atom->new('Undef') unless defined $value;

    if (my $rt = reftype($value)) {
        if ($rt eq 'ARRAY') {
            return _infer_array($value);
        }
        if ($rt eq 'HASH') {
            return _infer_hash($value);
        }
        if ($rt eq 'CODE') {
            return Typist::Type::Atom->new('Any');
        }
        return Typist::Type::Atom->new('Any');
    }

    # Scalar — narrow as far as possible
    return Typist::Type::Atom->new('Bool')
        if $value eq '1' || $value eq '0' || $value eq '';

    return Typist::Type::Atom->new('Int')
        if looks_like_number($value) && $value == int($value);

    return Typist::Type::Atom->new('Num')
        if looks_like_number($value);

    Typist::Type::Atom->new('Str');
}

sub _infer_array ($arr) {
    return Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Any'))
        unless @$arr;

    # Find the common supertype of all elements
    my $elem = __PACKAGE__->infer_value($arr->[0]);
    for my $i (1 .. $#$arr) {
        $elem = _common_super($elem, __PACKAGE__->infer_value($arr->[$i]));
    }
    Typist::Type::Param->new('ArrayRef', $elem);
}

sub _infer_hash ($hash) {
    return Typist::Type::Param->new('HashRef', Typist::Type::Atom->new('Any'))
        unless %$hash;

    my @vals = map { __PACKAGE__->infer_value($_) } values %$hash;
    my $vtype = $vals[0];
    for my $i (1 .. $#vals) {
        $vtype = _common_super($vtype, $vals[$i]);
    }
    Typist::Type::Param->new('HashRef', $vtype);
}

my %ATOM_ORDER = (Bool => 0, Int => 1, Num => 2, Str => 3, Any => 4);

sub _common_super ($a, $b) {
    return $a if $a->equals($b);

    if ($a->is_atom && $b->is_atom) {
        my $oa = $ATOM_ORDER{$a->name} // 4;
        my $ob = $ATOM_ORDER{$b->name} // 4;

        # If they're on the same numeric chain, return the higher one
        if (exists $ATOM_ORDER{$a->name} && exists $ATOM_ORDER{$b->name}) {
            if ($a->name ne 'Str' && $b->name ne 'Str') {
                return $oa > $ob ? $a : $b;
            }
        }
    }

    Typist::Type::Atom->new('Any');
}

# ── Generic Instantiation ────────────────────────

# Given a generic signature and actual argument types, produce variable bindings.
sub instantiate ($class, $sig, $arg_types) {
    my @formal = $sig->{params} ? $sig->{params}->@* : ();
    my @actual = @$arg_types;

    my %bindings;
    my $n = @formal < @actual ? @formal : @actual;
    for my $i (0 .. $n - 1) {
        _unify($formal[$i], $actual[$i], \%bindings);
    }
    \%bindings;
}

# ── HM-style Unification ─────────────────────────

sub _unify ($formal, $actual, $bindings) {
    # Type variable — bind or verify consistency
    if ($formal->is_var) {
        my $name = $formal->name;
        if (exists $bindings->{$name}) {
            # Already bound — check compatibility
            return if $bindings->{$name}->equals($actual);
            $bindings->{$name} = _common_super($bindings->{$name}, $actual);
        } else {
            $bindings->{$name} = $actual;
        }
        return;
    }

    # Parameterized — recurse into params
    if ($formal->is_param && $actual->is_param && $formal->base eq $actual->base) {
        my @fp = $formal->params;
        my @ap = $actual->params;
        my $n  = @fp < @ap ? @fp : @ap;
        _unify($fp[$_], $ap[$_], $bindings) for 0 .. $n - 1;
        return;
    }

    # Function types
    if ($formal->is_func && $actual->is_func) {
        my @fp = $formal->params;
        my @ap = $actual->params;
        my $n  = @fp < @ap ? @fp : @ap;
        _unify($fp[$_], $ap[$_], $bindings) for 0 .. $n - 1;
        _unify($formal->returns, $actual->returns, $bindings);
        return;
    }

    # Struct types
    if ($formal->is_struct && $actual->is_struct) {
        my %ff = $formal->fields;
        my %af = $actual->fields;
        for my $key (keys %ff) {
            _unify($ff{$key}, $af{$key}, $bindings) if exists $af{$key};
        }
        return;
    }
}

1;
