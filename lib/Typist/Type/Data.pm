package Typist::Type::Data;
use v5.40;
use parent 'Typist::Type';
use Scalar::Util 'blessed';

# Tagged union (algebraic data type):
#   datatype Shape => Circle => '(Int)', Rectangle => '(Int, Int)';
#
# Variants are stored as { Tag => [Type, ...], ... }.
# Values are blessed into "Typist::Data::$name" with _tag and _values fields.

sub new ($class, $name, $variants) {
    bless +{ name => $name, variants => $variants }, $class;
}

sub name     ($self) { $self->{name} }
sub variants ($self) { $self->{variants} }
sub is_data  ($self) { 1 }

sub to_string ($self) {
    my @parts;
    for my $tag (sort keys $self->{variants}->%*) {
        my @types = $self->{variants}{$tag}->@*;
        push @parts, @types
            ? "$tag(" . join(', ', map { $_->to_string } @types) . ")"
            : $tag;
    }
    join ' | ', @parts;
}

sub equals ($self, $other) {
    $other->is_data && $self->{name} eq $other->name;
}

sub contains ($self, $value) {
    return 0 unless defined $value && blessed($value);
    return 0 unless blessed($value) eq "Typist::Data::$self->{name}";
    my $tag = $value->{_tag};
    return 0 unless $tag && exists $self->{variants}{$tag};

    my @expected = $self->{variants}{$tag}->@*;
    my @actual   = ($value->{_values} // [])->@*;
    return 0 unless @actual == @expected;

    for my $i (0 .. $#expected) {
        return 0 unless $expected[$i]->contains($actual[$i]);
    }
    1;
}

sub free_vars ($self) {
    my %seen;
    for my $types (values $self->{variants}->%*) {
        $seen{$_} = 1 for map { $_->free_vars } @$types;
    }
    keys %seen;
}

sub substitute ($self, $bindings) {
    my %new_variants;
    for my $tag (keys $self->{variants}->%*) {
        $new_variants{$tag} = [
            map { $_->substitute($bindings) } $self->{variants}{$tag}->@*
        ];
    }
    __PACKAGE__->new($self->{name}, \%new_variants);
}

1;
