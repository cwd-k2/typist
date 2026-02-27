package Typist::Transform;
use v5.40;

use Typist::Type::Var;

# Walk a type tree, replacing Alias nodes whose names match declared
# type variable names with Var nodes.  Returns a new tree (no mutation).

sub aliases_to_vars ($class, $type, $var_names) {
    _walk($type, $var_names);
}

sub _walk ($type, $vars) {
    # Alias whose name is a declared type variable → Var
    if ($type->is_alias && $vars->{$type->alias_name}) {
        return Typist::Type::Var->new($type->alias_name);
    }

    # Recurse into composite types
    if ($type->is_param) {
        my @new = map { _walk($_, $vars) } $type->params;
        return Typist::Type::Param->new($type->base, @new);
    }
    if ($type->is_union) {
        return Typist::Type::Union->new(map { _walk($_, $vars) } $type->members);
    }
    if ($type->is_intersection) {
        return Typist::Type::Intersection->new(map { _walk($_, $vars) } $type->members);
    }
    if ($type->is_func) {
        my @new_p = map { _walk($_, $vars) } $type->params;
        my $new_r = _walk($type->returns, $vars);
        return Typist::Type::Func->new(\@new_p, $new_r);
    }
    if ($type->is_struct) {
        my %new;
        my %req = $type->required_fields;
        my %opt = $type->optional_fields;
        for my $key (keys %req) {
            $new{$key} = _walk($req{$key}, $vars);
        }
        for my $key (keys %opt) {
            $new{"${key}?"} = _walk($opt{$key}, $vars);
        }
        return Typist::Type::Struct->new(%new);
    }

    # Eff — recurse into inner Row
    if ($type->is_eff) {
        my $new_row = _walk($type->row, $vars);
        return $new_row->equals($type->row)
            ? $type
            : Typist::Type::Eff->new($new_row);
    }

    # Row — leaf-like; row_var might be an alias to transform
    if ($type->is_row) {
        my $var = $type->row_var;
        if (defined $var && $vars->{$var}) {
            # The row_var name matches a declared type variable — keep as-is
            # (Row stores row_var as a plain string, not a type node)
            return $type;
        }
        return $type;
    }

    # Atoms, Vars, Literals — leaf nodes, return as-is
    $type;
}

1;
