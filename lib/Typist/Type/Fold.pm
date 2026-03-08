package Typist::Type::Fold;
use v5.40;

our $VERSION = '0.01';

use Typist::Type::Param;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Record;
use Typist::Type::Struct;
use Typist::Type::Eff;
use Typist::Type::Data;
use Typist::Type::Quantified;

# ── Bottom-up Map ───────────────────────────────

# Rebuild a type tree bottom-up, applying $cb to each node after
# its children have been recursively mapped.
# $cb receives the (possibly rebuilt) node and returns a Type.
sub map_type ($class, $type, $cb) {
    if ($type->is_param) {
        my $new_base = $type->base;
        if (ref $new_base && $new_base->isa('Typist::Type')) {
            $new_base = $class->map_type($new_base, $cb);
        }
        my @new = map { $class->map_type($_, $cb) } $type->params;
        return $cb->(Typist::Type::Param->new($new_base, @new));
    }
    elsif ($type->is_union) {
        my @new = map { $class->map_type($_, $cb) } $type->members;
        return $cb->(Typist::Type::Union->new(@new));
    }
    elsif ($type->is_intersection) {
        my @new = map { $class->map_type($_, $cb) } $type->members;
        return $cb->(Typist::Type::Intersection->new(@new));
    }
    elsif ($type->is_func) {
        my @new_p = map { $class->map_type($_, $cb) } $type->params;
        my $new_r = $class->map_type($type->returns, $cb);
        my $new_e = $type->effects
            ? $class->map_type($type->effects, $cb) : undef;
        return $cb->(Typist::Type::Func->new(\@new_p, $new_r, $new_e));
    }
    elsif ($type->is_record) {
        my %req = $type->required_fields;
        my %opt = $type->optional_fields;
        my %new_req = map { $_ => $class->map_type($req{$_}, $cb) } keys %req;
        my %new_opt = map { $_ => $class->map_type($opt{$_}, $cb) } keys %opt;
        return $cb->(Typist::Type::Record->from_parts(
            required => \%new_req, optional => \%new_opt,
        ));
    }
    elsif ($type->is_struct) {
        my $new_record = $class->map_type($type->record, $cb);
        return $cb->(Typist::Type::Struct->new(
            name        => $type->name,
            record      => $new_record,
            package     => $type->package,
            type_params => [$type->type_params],
            type_args   => [map { $class->map_type($_, $cb) } $type->type_args],
        ));
    }
    elsif ($type->is_eff) {
        my $new_row = $class->map_type($type->row, $cb);
        return $cb->(Typist::Type::Eff->new($new_row));
    }
    elsif ($type->is_data) {
        my %new_variants;
        for my $tag (keys $type->variants->%*) {
            $new_variants{$tag} = [
                map { $class->map_type($_, $cb) } $type->variants->{$tag}->@*
            ];
        }
        my %new_rt;
        for my $tag (keys $type->return_types->%*) {
            $new_rt{$tag} = $class->map_type($type->return_types->{$tag}, $cb);
        }
        return $cb->(Typist::Type::Data->new($type->name, \%new_variants,
            type_params  => [$type->type_params],
            type_args    => [map { $class->map_type($_, $cb) } $type->type_args],
            return_types => \%new_rt,
        ));
    }
    elsif ($type->is_quantified) {
        my @new_vars = map {
            $_->{bound}
                ? +{ name => $_->{name}, bound => $class->map_type($_->{bound}, $cb) }
                : +{ %$_ }
        } $type->vars;
        my $new_body = $class->map_type($type->body, $cb);
        return $cb->(Typist::Type::Quantified->new(vars => \@new_vars, body => $new_body));
    }

    # Leaf nodes: Atom, Var, Alias, Literal, Newtype, Row
    $cb->($type);
}

# ── Top-down Walk ───────────────────────────────

# Visit every node in the type tree, calling $cb for side effects.
# Children are visited after the parent.
sub walk ($class, $type, $cb) {
    $cb->($type);

    if ($type->is_param) {
        my $base = $type->base;
        $class->walk($base, $cb) if ref $base && $base->isa('Typist::Type');
        $class->walk($_, $cb) for $type->params;
    }
    elsif ($type->is_union)        { $class->walk($_, $cb) for $type->members }
    elsif ($type->is_intersection) { $class->walk($_, $cb) for $type->members }
    elsif ($type->is_func) {
        $class->walk($_, $cb) for $type->params;
        $class->walk($type->returns, $cb);
        $class->walk($type->effects, $cb) if $type->effects;
    }
    elsif ($type->is_record) {
        my %r = $type->required_fields;
        my %o = $type->optional_fields;
        $class->walk($_, $cb) for values %r, values %o;
    }
    elsif ($type->is_struct) {
        $class->walk($type->record, $cb);
    }
    elsif ($type->is_row) {
        $class->walk($type->row_var, $cb) if $type->row_var;
    }
    elsif ($type->is_eff) {
        $class->walk($type->row, $cb);
    }
    elsif ($type->is_data) {
        for my $types (values $type->variants->%*) {
            $class->walk($_, $cb) for @$types;
        }
        $class->walk($_, $cb) for $type->type_args;
        $class->walk($_, $cb) for values $type->return_types->%*;
    }
    elsif ($type->is_quantified) {
        for my $v ($type->vars) {
            $class->walk($v->{bound}, $cb) if $v->{bound};
        }
        $class->walk($type->body, $cb);
    }

    return;
}

1;

=head1 NAME

Typist::Type::Fold - Type tree traversal utilities

=head1 SYNOPSIS

    use Typist::Type::Fold;

    # Bottom-up rebuild
    my $new = Typist::Type::Fold->map_type($type, sub ($node) {
        $node->is_alias ? resolve($node) : $node;
    });

    # Top-down side-effect walk
    Typist::Type::Fold->walk($type, sub ($node) {
        push @vars, $node->name if $node->is_var;
    });

=head1 DESCRIPTION

Provides two traversal strategies for type trees:

C<map_type> rebuilds bottom-up, applying a callback to each node after
its children have been mapped. C<walk> visits top-down, calling a
callback for side effects.

Both handle all type nodes: Param, Union, Intersection, Func, Record,
Struct, Eff, Data (variants, type_args, return_types), and Quantified
(body + var bounds).

=head1 METHODS

=head2 map_type

    my $new = Typist::Type::Fold->map_type($type, \&callback);

Bottom-up rebuild. C<$callback> receives a (possibly rebuilt) node
and returns a Type.

=head2 walk

    Typist::Type::Fold->walk($type, \&callback);

Top-down visit. C<$callback> receives each node for side effects.

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Transform>

=cut
