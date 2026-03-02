package Typist::Type::Atom;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use Scalar::Util 'looks_like_number';

# Flyweight — one instance per primitive name.
my %POOL;

my %VALIDATORS = (
    Any   => sub { 1 },
    Void  => sub { 0 },
    Never => sub { 0 },
    Undef => sub { !defined $_[0] },
    Bool  => sub { defined $_[0] && !ref $_[0] && ($_[0] eq '1' || $_[0] eq '0' || $_[0] eq '' ) },
    Int   => sub { defined $_[0] && !ref $_[0] && looks_like_number($_[0]) && $_[0] == int($_[0]) },
    Num   => sub { defined $_[0] && !ref $_[0] && looks_like_number($_[0]) },
    Str   => sub { defined $_[0] && !ref $_[0] },
);

sub new ($class, $name) {
    $POOL{$name} //= bless +{ name => $name }, $class;
}

sub name      ($self) { $self->{name} }
sub to_string ($self) { $self->{name} }
sub is_atom   ($self) { 1 }

sub equals ($self, $other) {
    $other->is_atom && $self->{name} eq $other->name;
}

sub contains ($self, $value) {
    my $check = $VALIDATORS{$self->{name}} // sub { 1 };
    $check->($value);
}

sub free_vars  ($self) { () }
sub substitute ($self, $) { $self }

1;

=head1 NAME

Typist::Type::Atom - Primitive type atoms (Int, Str, Bool, ...)

=head1 SYNOPSIS

    use Typist::Type::Atom;

    my $int = Typist::Type::Atom->new('Int');
    $int->contains(42);    # true
    $int->contains("hi");  # false

=head1 DESCRIPTION

Singleton flyweight type for primitive types. Each name (C<Int>, C<Str>,
C<Num>, C<Bool>, C<Any>, C<Void>, C<Never>, C<Undef>) maps to exactly
one blessed instance in a package-level pool.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_atom> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Type::Literal>

=cut
