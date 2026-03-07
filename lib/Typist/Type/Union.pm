package Typist::Type::Union;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use List::Util 'any', 'all';

# Union type: T | U
# Constructor flattens nested unions and deduplicates members.

sub new ($class, @members) {
    # Flatten nested unions
    my @flat;
    for my $m (@members) {
        if ($m->is_union) {
            push @flat, $m->members;
        } else {
            push @flat, $m;
        }
    }

    # Deduplicate by structural equality
    my @unique;
    for my $candidate (@flat) {
        push @unique, $candidate
            unless any { $_->equals($candidate) } @unique;
    }

    # A single-member union collapses to the member itself
    return $unique[0] if @unique == 1;

    bless +{ members => \@unique }, $class;
}

sub members  ($self) { $self->{members}->@* }
sub is_union ($self) { 1 }

sub name ($self) { $self->to_string }

sub to_string ($self) {
    join ' | ', map {
        $_->is_func ? '(' . $_->to_string . ')' : $_->to_string
    } $self->{members}->@*;
}

sub equals ($self, $other) {
    return 0 unless $other->is_union;

    my @sm = $self->{members}->@*;
    my @om = $other->members;
    return 0 unless @sm == @om;

    # Every member in self has an equal in other, and vice versa
    (all { my $s = $_; any { $s->equals($_) } @om } @sm)
        && (all { my $o = $_; any { $o->equals($_) } @sm } @om);
}

sub contains ($self, $value) {
    any { $_->contains($value) } $self->{members}->@*;
}

sub free_vars ($self) {
    map { $_->free_vars } $self->{members}->@*;
}

sub substitute ($self, $bindings) {
    __PACKAGE__->new(map { $_->substitute($bindings) } $self->{members}->@*);
}

1;

=head1 NAME

Typist::Type::Union - Union type (T | U)

=head1 SYNOPSIS

    use Typist::Type::Union;

    my $u = Typist::Type::Union->new($int_type, $str_type);

=head1 DESCRIPTION

A value satisfies a union type if it satisfies B<any> member.
The constructor flattens nested unions and deduplicates members by
structural equality. A single-member union collapses to the member
itself.

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_union> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head2 members

    my @members = $union->members;

Returns the union's member types.

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Type::Intersection>

=cut
