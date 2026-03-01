package Typist::Type::Literal;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use Scalar::Util 'looks_like_number';

# Singleton literal type: Literal("hello"), Literal(42), etc.
# A value matches iff it is string-equal to the stored literal.

sub new ($class, $value, $base_type) {
    bless +{ value => $value, base_type => $base_type }, $class;
}

sub value     ($self) { $self->{value} }
sub base_type ($self) { $self->{base_type} }
sub is_literal ($self) { 1 }

sub name ($self) { $self->to_string }

sub to_string ($self) {
    my $v = $self->{value};
    if ($self->{base_type} eq 'Str') {
        return qq{"$v"};
    }
    "$v";
}

sub equals ($self, $other) {
    return 0 unless $other->is_literal;
    "$self->{value}" eq "${\$other->value}"
        && $self->{base_type} eq $other->base_type;
}

sub contains ($self, $value) {
    return 0 unless defined $value;
    "$value" eq "$self->{value}";
}

sub free_vars  ($self) { () }
sub substitute ($self, $) { $self }

1;
