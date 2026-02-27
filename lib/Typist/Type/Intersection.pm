package Typist::Type::Intersection;
use v5.40;
use parent 'Typist::Type';
use List::Util 'any', 'all';

# Intersection type: T & U
# A value must satisfy ALL member types.

sub new ($class, @members) {
    # Flatten nested intersections
    my @flat;
    for my $m (@members) {
        if ($m->is_intersection) {
            push @flat, $m->members;
        } else {
            push @flat, $m;
        }
    }

    # Deduplicate
    my @unique;
    for my $candidate (@flat) {
        push @unique, $candidate
            unless any { $_->equals($candidate) } @unique;
    }

    return $unique[0] if @unique == 1;

    bless +{ members => \@unique }, $class;
}

sub members         ($self) { $self->{members}->@* }
sub is_intersection ($self) { 1 }

sub name ($self) { $self->to_string }

sub to_string ($self) {
    join ' & ', map { $_->to_string } $self->{members}->@*;
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
