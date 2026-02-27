package Typist::Type::Var;
use v5.40;
use parent 'Typist::Type';

# Generic type variable: T, U, etc.

sub new ($class, $name, %opts) {
    bless +{ name => $name, bound => $opts{bound}, kind => $opts{kind} }, $class;
}

sub name     ($self) { $self->{name} }
sub bound    ($self) { $self->{bound} }
sub kind     ($self) { $self->{kind} }
sub is_var   ($self) { 1 }

sub to_string ($self) {
    if ($self->{bound}) {
        return "$self->{name}: " . $self->{bound}->to_string;
    }
    $self->{name};
}

sub equals ($self, $other) {
    $other->is_var && $self->{name} eq $other->name;
}

sub contains ($self, $) { 1 }

sub free_vars ($self) { ($self->{name}) }

sub substitute ($self, $bindings) {
    $bindings->{$self->{name}} // $self;
}

1;
