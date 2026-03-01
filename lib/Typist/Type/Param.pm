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

    if ($base eq 'ArrayRef') {
        return 0 unless defined $value && ref $value && reftype($value) eq 'ARRAY';
        return 1 unless @params;
        return all { $params[0]->contains($_) } @$value;
    }

    if ($base eq 'HashRef') {
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
        $new_base = $new_base->substitute($bindings);
        # Normalize: Alias/Atom results collapse to string names.
        if (ref $new_base && $new_base->isa('Typist::Type')) {
            if ($new_base->is_alias) {
                $new_base = $new_base->alias_name;
            } elsif ($new_base->is_atom) {
                $new_base = $new_base->name;
            }
        }
    }
    my @new_params = map { $_->substitute($bindings) } $self->{params}->@*;
    __PACKAGE__->new($new_base, @new_params);
}

1;
