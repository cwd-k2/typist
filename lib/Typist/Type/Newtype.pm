package Typist::Type::Newtype;
use v5.40;
use parent 'Typist::Type';
use Scalar::Util 'blessed';

# Nominal wrapper type: newtype UserId => 'Int'
# Values must be blessed into "Typist::Newtype::$name" and inner must pass.

sub new ($class, $name, $inner) {
    bless +{ name => $name, inner => $inner }, $class;
}

sub name      ($self) { $self->{name} }
sub inner     ($self) { $self->{inner} }
sub is_newtype ($self) { 1 }

sub to_string ($self) {
    "$self->{name}";
}

sub equals ($self, $other) {
    $other->is_newtype && $self->{name} eq $other->name;
}

sub contains ($self, $value) {
    return 0 unless defined $value && blessed($value);
    return 0 unless blessed($value) eq "Typist::Newtype::$self->{name}";
    $self->{inner}->contains($$value);
}

sub free_vars ($self) { $self->{inner}->free_vars }

sub substitute ($self, $bindings) {
    my $new_inner = $self->{inner}->substitute($bindings);
    __PACKAGE__->new($self->{name}, $new_inner);
}

1;
