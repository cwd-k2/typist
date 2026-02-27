package Typist::Type::Var;
use v5.40;
use parent 'Typist::Type';

# Generic type variable: T, U, etc.

sub new ($class, $name) {
    bless { name => $name }, $class;
}

sub name     ($self) { $self->{name} }
sub is_var   ($self) { 1 }

sub to_string ($self) { $self->{name} }

sub equals ($self, $other) {
    $other->is_var && $self->{name} eq $other->name;
}

sub contains ($self, $) { 1 }

sub free_vars ($self) { ($self->{name}) }

sub substitute ($self, $bindings) {
    $bindings->{$self->{name}} // $self;
}

1;
