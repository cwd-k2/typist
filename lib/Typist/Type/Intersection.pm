package Typist::Type::Intersection;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use List::Util 'any', 'all';

# Intersection type: T & U
# A value must satisfy ALL member types.

sub new ($class, @members) {
    my @unique = Typist::Type->_normalize_members('is_intersection', @members);
    return $unique[0] if @unique == 1;
    bless +{ members => \@unique }, $class;
}

sub members        ($self) { $self->{members}->@* }
sub is_intersection ($self) { 1 }

sub name ($self) { $self->to_string }

sub to_string ($self) {
    join ' & ', map {
        ($_->is_func || $_->is_union) ? '(' . $_->to_string . ')' : $_->to_string
    } $self->{members}->@*;
}

sub equals ($self, $other) {
    return 0 unless $other->is_intersection;

    my @sm = $self->{members}->@*;
    my @om = $other->members;
    return 0 unless @sm == @om;

    (all { my $s = $_; any { $s->equals($_) } @om } @sm)
        && (all { my $o = $_; any { $o->equals($_) } @sm } @om);
}

sub contains ($self, $value) {
    all { $_->contains($value) } $self->{members}->@*;
}

sub free_vars ($self) {
    map { $_->free_vars } $self->{members}->@*;
}

sub substitute ($self, $bindings) {
    __PACKAGE__->new(map { $_->substitute($bindings) } $self->{members}->@*);
}

1;

=head1 NAME

Typist::Type::Intersection - Intersection type (T & U)

=head1 SYNOPSIS

    use Typist::Type::Intersection;

    my $i = Typist::Type::Intersection->new($type_a, $type_b);

=head1 DESCRIPTION

A value satisfies an intersection type if it satisfies B<all> members.
The constructor flattens nested intersections and deduplicates members.
A single-member intersection collapses to the member itself.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_intersection>
(returns 1), C<name>, C<to_string>, C<equals>, C<contains>,
C<free_vars>, C<substitute>.

=head2 members

    my @members = $intersection->members;

Returns the intersection's member types.

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Type::Union>

=cut
