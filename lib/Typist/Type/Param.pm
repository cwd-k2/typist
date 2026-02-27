package Typist::Type::Param;
use v5.40;
use parent 'Typist::Type';
use Scalar::Util 'reftype';
use List::Util  'all';

# Parameterized types: ArrayRef[T], HashRef[K,V], Tuple[T,U,...], etc.

sub new ($class, $base, @params) {
    bless { base => $base, params => \@params }, $class;
}

sub base     ($self) { $self->{base} }
sub params   ($self) { $self->{params}->@* }
sub is_param ($self) { 1 }

sub name ($self) {
    $self->{base};
}

sub to_string ($self) {
    my $inner = join ', ', map { $_->to_string } $self->{params}->@*;
    "$self->{base}\[$inner]";
}

sub equals ($self, $other) {
    return 0 unless $other->is_param;
    return 0 unless $self->{base} eq $other->base;

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
    map { $_->free_vars } $self->{params}->@*;
}

sub substitute ($self, $bindings) {
    my @new_params = map { $_->substitute($bindings) } $self->{params}->@*;
    __PACKAGE__->new($self->{base}, @new_params);
}

1;
