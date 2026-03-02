package Typist::Inference;
use v5.40;

our $VERSION = '0.01';

use Scalar::Util 'looks_like_number', 'reftype';
use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Record;
use Typist::Subtype;

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
        $elem = Typist::Subtype->common_super($elem, __PACKAGE__->infer_value($arr->[$i]));
    }
    Typist::Type::Param->new('ArrayRef', $elem);
}

sub _infer_hash ($hash) {
    return Typist::Type::Param->new('HashRef', Typist::Type::Atom->new('Any'))
        unless %$hash;

    my @vals = map { __PACKAGE__->infer_value($_) } values %$hash;
    my $vtype = $vals[0];
    for my $i (1 .. $#vals) {
        $vtype = Typist::Subtype->common_super($vtype, $vals[$i]);
    }
    Typist::Type::Param->new('HashRef', $vtype);
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
            $bindings->{$name} = Typist::Subtype->common_super($bindings->{$name}, $actual);
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
        # Unify effects if both present
        if ($formal->effects && $actual->effects) {
            _unify_rows($formal->effects, $actual->effects, $bindings);
        }
        return;
    }

    # Eff types — delegate to Row unification
    if ($formal->is_eff && $actual->is_eff) {
        _unify_rows($formal->row, $actual->row, $bindings);
        return;
    }

    # Row types — Rémy-style row unification
    if ($formal->is_row && $actual->is_row) {
        _unify_rows($formal, $actual, $bindings);
        return;
    }

    # Struct types — unify required and optional fields separately
    if ($formal->is_record && $actual->is_record) {
        my %freq = $formal->required_fields;
        my %fopt = $formal->optional_fields;
        my %areq = $actual->required_fields;
        my %aopt = $actual->optional_fields;
        for my $key (keys %freq) {
            if (exists $areq{$key}) {
                _unify($freq{$key}, $areq{$key}, $bindings);
            } elsif (exists $aopt{$key}) {
                _unify($freq{$key}, $aopt{$key}, $bindings);
            }
        }
        for my $key (keys %fopt) {
            if (exists $areq{$key}) {
                _unify($fopt{$key}, $areq{$key}, $bindings);
            } elsif (exists $aopt{$key}) {
                _unify($fopt{$key}, $aopt{$key}, $bindings);
            }
        }
        return;
    }
}

# ── Rémy-style Row Unification ──────────────────

sub _unify_rows ($formal, $actual, $bindings) {
    require Typist::Type::Row;

    my %fl = map { $_ => 1 } $formal->labels;
    my %al = map { $_ => 1 } $actual->labels;

    # Common labels cancel out
    my @common = grep { $al{$_} } keys %fl;
    delete @fl{@common};
    delete @al{@common};

    my @formal_excess = sort keys %fl;
    my @actual_excess = sort keys %al;

    # Bind formal's row_var to actual's excess labels + actual's tail
    if (defined $formal->row_var_name) {
        my $name = $formal->row_var_name;
        my $bound = Typist::Type::Row->new(
            labels  => \@actual_excess,
            row_var => $actual->row_var,
        );
        $bindings->{$name} = $bound;
    }

    # Bind actual's row_var to formal's excess labels + formal's tail
    if (defined $actual->row_var_name) {
        my $name = $actual->row_var_name;
        my $bound = Typist::Type::Row->new(
            labels  => \@formal_excess,
            row_var => $formal->row_var,
        );
        $bindings->{$name} = $bound;
    }
}

1;
