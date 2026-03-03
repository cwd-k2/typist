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

    # Unknown parameterized type — be permissive
    1;
}

sub free_vars ($self) {
    my @base_vars;
    if (ref $self->{base} && $self->{base}->isa('Typist::Type')) {
        @base_vars = $self->{base}->free_vars;
    }
    (@base_vars, map { $_->free_vars } $self->{params}->@*);
}

sub substitute ($self, $bindings) {
    my $new_base = $self->{base};
    if (ref $new_base && $new_base->isa('Typist::Type')) {
        if ($new_base->is_alias) {
            # Alias base = type constructor name reference (e.g. Option in
            # Option[B]).  Extract the name directly — do NOT resolve through
            # the registry, which would turn it into a Data/Param type and
            # produce double-nesting like Option[T][B].
            $new_base = $new_base->alias_name;
        } else {
            $new_base = $new_base->substitute($bindings);
            # Normalize: collapse type objects to string names.
            if (ref $new_base && $new_base->isa('Typist::Type')) {
                if ($new_base->is_alias) {
                    $new_base = $new_base->alias_name;
                } elsif ($new_base->is_atom) {
                    $new_base = $new_base->name;
                } elsif ($new_base->is_data) {
                    $new_base = $new_base->name;
                } elsif ($new_base->is_param) {
                    $new_base = ref($new_base->base) ? "${\$new_base->base}" : $new_base->base;
                }
            }
        }
    }
    my @new_params = map { $_->substitute($bindings) } $self->{params}->@*;
    __PACKAGE__->new($new_base, @new_params);
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
