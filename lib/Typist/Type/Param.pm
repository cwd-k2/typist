package Typist::Type::Param;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use Scalar::Util 'reftype';
use List::Util  'all';

# Parameterized types: ArrayRef[T], HashRef[K,V], Tuple[T,U,...], etc.
# Base may be a string name (e.g. 'ArrayRef') or a Typist::Type object
# (e.g. Var('F')) for type variable application in HKT contexts.

sub new ($class, $base, @params) {
    bless +{ base => $base, params => \@params }, $class;
}

sub base     ($self) { $self->{base} }
sub params   ($self) { $self->{params}->@* }
sub is_param ($self) { 1 }

# Whether the base is a type variable (HKT application).
sub has_var_base ($self) {
    ref $self->{base} && $self->{base}->isa('Typist::Type') && $self->{base}->is_var;
}

sub name ($self) {
    $self->{base};
}

sub to_string ($self) {
    my $inner = join ', ', map { $_->to_string } $self->{params}->@*;
    "$self->{base}\[$inner]";
}

sub equals ($self, $other) {
    return 0 unless $other->is_param;

    # Compare bases: both may be strings or Type objects.
    # String comparison via eq works for both (Type objects stringify via overload).
    my ($sb, $ob) = ($self->{base}, $other->base);
    if (ref $sb && $sb->isa('Typist::Type') && ref $ob && $ob->isa('Typist::Type')) {
        return 0 unless $sb->equals($ob);
    } else {
        return 0 unless "$sb" eq "$ob";
    }

    my @sp = $self->{params}->@*;
    my @op = $other->params;
    return 0 unless @sp == @op;

    all { $sp[$_]->equals($op[$_]) } 0 .. $#sp;
}

sub contains ($self, $value) {
    my $base   = $self->{base};
    my @params = $self->{params}->@*;

    if ($base eq 'ArrayRef' || $base eq 'Array') {
        return 0 unless defined $value && ref $value && reftype($value) eq 'ARRAY';
        return 1 unless @params;
        return all { $params[0]->contains($_) } @$value;
    }

    if ($base eq 'HashRef' || $base eq 'Hash') {
        return 0 unless defined $value && ref $value && reftype($value) eq 'HASH';
        if (@params >= 2) {
            return (all { $params[0]->contains($_) } keys   %$value)
                && (all { $params[1]->contains($_) } values %$value);
        }
        if (@params == 1) {
            return all { $params[0]->contains($_) } values %$value;
        }
        return 1;
    }

    if ($base eq 'Tuple') {
        return 0 unless defined $value && ref $value && reftype($value) eq 'ARRAY';
        return 0 unless @$value == @params;
        return all { $params[$_]->contains($value->[$_]) } 0 .. $#params;
    }

    if ($base eq 'Ref') {
        return 0 unless defined $value && ref $value;
        return 1 unless @params;
        return $params[0]->contains($$value);
    }

    if ($base eq 'Handler' && @params == 1) {
        return 0 unless defined $value && ref $value && reftype($value) eq 'HASH';
        my $effect_ref = $params[0];
        my $effect_name = ref $effect_ref && $effect_ref->isa('Typist::Type')
            ? ($effect_ref->is_alias ? $effect_ref->alias_name : "$effect_ref")
            : "$effect_ref";
        require Typist::Registry;
        my $effect = Typist::Registry->lookup_effect($effect_name) // return 0;
        for my $op ($effect->op_names) {
            return 0 unless exists $value->{$op};
            my $op_type = $effect->get_op_type($op) // return 0;
            return 0 unless $op_type->contains($value->{$op});
        }
        return 1;
    }

    # Unknown parameterized type — be permissive
    1;
}

sub free_vars ($self) {
    my @fv;
    if (ref $self->{base} && $self->{base}->isa('Typist::Type')) {
        push @fv, $self->{base}->free_vars;
    }
    push @fv, map { $_->free_vars } $self->{params}->@*;
    @fv;
}

sub substitute ($self, $bindings) {
    my $new_base = $self->{base};
    if (ref $new_base && $new_base->isa('Typist::Type')) {
        # Alias base = type constructor name reference (e.g. Option in
        # Option[B]).  Extract the name directly — do NOT resolve through
        # the registry, which would turn it into a Data/Param type and
        # produce double-nesting like Option[T][B].
        $new_base = $new_base->is_alias
            ? $new_base->alias_name
            : $new_base->substitute($bindings);
        # Normalize: collapse type objects to string base names
        $new_base = _extract_base_name($new_base)
            if ref $new_base && $new_base->isa('Typist::Type');
    }
    my @new_params = map { $_->substitute($bindings) } $self->{params}->@*;
    __PACKAGE__->new($new_base, @new_params);
}

# Collapse a type object to its string base name where applicable.
sub _extract_base_name ($type) {
    return $type->alias_name if $type->is_alias;
    return $type->name       if $type->is_atom || $type->is_data;
    return "${\$type->base}" if $type->is_param && ref $type->base;
    return $type->base       if $type->is_param;
    $type;
}

1;

=head1 NAME

Typist::Type::Param - Parameterized type (ArrayRef[T], HashRef[K,V], ...)

=head1 SYNOPSIS

    use Typist::Type::Param;

    my $arr = Typist::Type::Param->new('ArrayRef', $int_type);

=head1 DESCRIPTION

Represents parameterized types such as C<ArrayRef[Int]>,
C<HashRef[Str, Int]>, C<Tuple[Int, Str]>, and C<Ref[Int]>. The base
may be a string name or a L<Typist::Type> object (for HKT variable
application: C<F[T]>).

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_param> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head2 base

    my $base = $param->base;

Returns the base type constructor name or Type object.

=head2 params

    my @params = $param->params;

Returns the type parameters.

=head2 has_var_base

    my $bool = $param->has_var_base;

True if the base is a type variable (HKT context).

=head1 SEE ALSO

L<Typist::Type>, L<Typist::KindChecker>

=cut
