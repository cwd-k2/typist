package Typist::Type::Fold;
use v5.40;

use Typist::Type::Param;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Struct;
use Typist::Type::Eff;

# ── Bottom-up Map ───────────────────────────────

# Rebuild a type tree bottom-up, applying $cb to each node after
# its children have been recursively mapped.
# $cb receives the (possibly rebuilt) node and returns a Type.
sub map_type ($class, $type, $cb) {
    if ($type->is_param) {
        my @new = map { $class->map_type($_, $cb) } $type->params;
        return $cb->(Typist::Type::Param->new($type->base, @new));
    }
    if ($type->is_union) {
        my @new = map { $class->map_type($_, $cb) } $type->members;
        return $cb->(Typist::Type::Union->new(@new));
    }
    if ($type->is_intersection) {
        my @new = map { $class->map_type($_, $cb) } $type->members;
        return $cb->(Typist::Type::Intersection->new(@new));
    }
    if ($type->is_func) {
        my @new_p = map { $class->map_type($_, $cb) } $type->params;
        my $new_r = $class->map_type($type->returns, $cb);
        my $new_e = $type->effects
            ? $class->map_type($type->effects, $cb) : undef;
        return $cb->(Typist::Type::Func->new(\@new_p, $new_r, $new_e));
    }
    if ($type->is_struct) {
        my %req = $type->required_fields;
        my %opt = $type->optional_fields;
        my %new_req = map { $_ => $class->map_type($req{$_}, $cb) } keys %req;
        my %new_opt = map { $_ => $class->map_type($opt{$_}, $cb) } keys %opt;
        return $cb->(Typist::Type::Struct->from_parts(
            required => \%new_req, optional => \%new_opt,
        ));
    }
    if ($type->is_eff) {
        my $new_row = $class->map_type($type->row, $cb);
        return $cb->(Typist::Type::Eff->new($new_row));
    }

    # Leaf nodes: Atom, Var, Alias, Literal, Newtype, Row
    $cb->($type);
}

# ── Top-down Walk ───────────────────────────────

# Visit every node in the type tree, calling $cb for side effects.
# Children are visited after the parent.
sub walk ($class, $type, $cb) {
    $cb->($type);

    if    ($type->is_param)        { $class->walk($_, $cb) for $type->params }
    elsif ($type->is_union)        { $class->walk($_, $cb) for $type->members }
    elsif ($type->is_intersection) { $class->walk($_, $cb) for $type->members }
    elsif ($type->is_func) {
        $class->walk($_, $cb) for $type->params;
        $class->walk($type->returns, $cb);
        $class->walk($type->effects, $cb) if $type->effects;
    }
    elsif ($type->is_struct) {
        my %r = $type->required_fields;
        my %o = $type->optional_fields;
        $class->walk($_, $cb) for values %r, values %o;
    }
    elsif ($type->is_eff) {
        $class->walk($type->row, $cb);
    }

    return;
}

1;
