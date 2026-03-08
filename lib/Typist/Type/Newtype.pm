package Typist::Type::Newtype;
use v5.40;

our $VERSION = '0.01';

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

sub to_string ($self) { $self->{name} }

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

=head1 NAME

Typist::Type::Newtype - Nominal wrapper type (newtype UserId => 'Int')

=head1 SYNOPSIS

    use Typist::Type::Newtype;

    my $nt = Typist::Type::Newtype->new('UserId', $int_type);

=head1 DESCRIPTION

A nominal wrapper that creates a distinct type from an existing inner
type. Values must be blessed into C<Typist::Newtype::$name> and the
inner value must satisfy the inner type. Type validation in the
constructor requires C<-runtime>; without it, the value is wrapped
without type checking.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_newtype> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head2 inner

    my $inner = $nt->inner;

Returns the wrapped inner type.

=head1 SEE ALSO

L<Typist::Type>, L<Typist>

=cut
