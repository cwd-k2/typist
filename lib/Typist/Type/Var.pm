package Typist::Type::Var;
use v5.40;

our $VERSION = '0.01';

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

=head1 NAME

Typist::Type::Var - Generic type variable (T, U, V, ...)

=head1 SYNOPSIS

    use Typist::Type::Var;

    my $t = Typist::Type::Var->new('T');
    my $bounded = Typist::Type::Var->new('T', bound => $num_type);

=head1 DESCRIPTION

Represents a generic type variable with optional upper bound and kind.
Free type variables are substituted during generic instantiation.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_var> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head2 bound

    my $bound = $var->bound;

Returns the upper bound type, or C<undef> if unbounded.

=head2 kind

    my $kind = $var->kind;

Returns the L<Typist::Kind> object, or C<undef>.

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Type::Quantified>

=cut
