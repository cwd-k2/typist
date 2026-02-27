package Typist::Effect;
use v5.40;

# Effect definition structure.
# Mirrors TypeClass::Def pattern: a named bag of typed operations.
#
#   { name => 'Console', operations => { readLine => 'CodeRef[-> Str]', ... } }

sub new ($class, %args) {
    bless +{
        name       => ($args{name}       // die("Effect requires name\n")),
        operations => ($args{operations} // +{}),
    }, $class;
}

sub name       ($self) { $self->{name} }
sub operations ($self) { $self->{operations}->%* }

sub op_names ($self) { sort keys $self->{operations}->%* }

sub get_op ($self, $name) { $self->{operations}{$name} }

1;
