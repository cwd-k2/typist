package Typist::Type::Struct;
use v5.40;
use parent 'Typist::Type';
use Scalar::Util 'reftype';
use List::Util   'all';

# Structural record type: { key => Type, ... }

sub new ($class, %fields) {
    bless +{ fields => \%fields }, $class;
}

sub fields    ($self) { %{$self->{fields}} }
sub field_ref ($self) { $self->{fields} }
sub is_struct ($self) { 1 }

sub name ($self) { $self->to_string }

sub to_string ($self) {
    my $f = $self->{fields};
    my $inner = join ', ', map { "$_ => " . $f->{$_}->to_string } sort keys %$f;
    "{ $inner }";
}

sub equals ($self, $other) {
    return 0 unless $other->is_struct;

    my %sf = %{$self->{fields}};
    my %of = $other->fields;

    my @sk = sort keys %sf;
    my @ok = sort keys %of;
    return 0 unless @sk == @ok;
    return 0 unless all { $sk[$_] eq $ok[$_] } 0 .. $#sk;

    all { $sf{$_}->equals($of{$_}) } @sk;
}

sub contains ($self, $value) {
    return 0 unless defined $value && ref $value && reftype($value) eq 'HASH';
    my %f = %{$self->{fields}};
    all { exists $value->{$_} && $f{$_}->contains($value->{$_}) } keys %f;
}

sub free_vars ($self) {
    map { $_->free_vars } values %{$self->{fields}};
}

sub substitute ($self, $bindings) {
    my %new = map { $_ => $self->{fields}{$_}->substitute($bindings) }
              keys %{$self->{fields}};
    __PACKAGE__->new(%new);
}

1;
