package Typist::Type::Data;
use v5.40;
use parent 'Typist::Type';
use Scalar::Util 'blessed';

# Tagged union (algebraic data type):
#   datatype Shape => Circle => '(Int)', Rectangle => '(Int, Int)';
#
# Parameterized:
#   datatype 'Option[T]' => Some => '(T)', None => '()';
#
# Variants are stored as { Tag => [Type, ...], ... }.
# Values are blessed into "Typist::Data::$name" with _tag, _values, and
# optional _type_args fields.

sub new ($class, $name, $variants, %opts) {
    bless +{
        name        => $name,
        variants    => $variants,
        type_params => $opts{type_params} // [],
        type_args   => $opts{type_args}   // [],   # concrete args for instantiated type
    }, $class;
}

sub name        ($self) { $self->{name} }
sub variants    ($self) { $self->{variants} }
sub type_params ($self) { $self->{type_params}->@* }
sub type_args   ($self) { $self->{type_args}->@* }
sub is_data     ($self) { 1 }

sub to_string ($self) {
    my $base = $self->{name};
    if ($self->{type_args}->@*) {
        $base .= '[' . join(', ', map { $_->to_string } $self->{type_args}->@*) . ']';
    } elsif ($self->{type_params}->@*) {
        $base .= '[' . join(', ', $self->{type_params}->@*) . ']';
    }
    # For display, just show the base name (not all variants)
    $base;
}

sub to_string_full ($self) {
    my @parts;
    for my $tag (sort keys $self->{variants}->%*) {
        my @types = $self->{variants}{$tag}->@*;
        push @parts, @types
            ? "$tag(" . join(', ', map { $_->to_string } @types) . ")"
            : $tag;
    }
    my $variants = join ' | ', @parts;
    my $name = $self->to_string;
    "$name = $variants";
}

sub equals ($self, $other) {
    return 0 unless $other->is_data && $self->{name} eq $other->name;

    # Compare type_args if present
    my @sa = $self->{type_args}->@*;
    my @oa = $other->type_args;
    return 1 if !@sa && !@oa;
    return 0 if @sa != @oa;
    for my $i (0 .. $#sa) {
        return 0 unless $sa[$i]->equals($oa[$i]);
    }
    1;
}

sub contains ($self, $value) {
    return 0 unless defined $value && blessed($value);
    return 0 unless blessed($value) eq "Typist::Data::$self->{name}";
    my $tag = $value->{_tag};
    return 0 unless $tag && exists $self->{variants}{$tag};

    my @expected = $self->{variants}{$tag}->@*;
    my @actual   = ($value->{_values} // [])->@*;
    return 0 unless @actual == @expected;

    # If we have concrete type_args, substitute into expected types
    my %bindings;
    if ($self->{type_args}->@* && $self->{type_params}->@*) {
        for my $i (0 .. $#{$self->{type_params}}) {
            $bindings{$self->{type_params}[$i]} = $self->{type_args}[$i]
                if $i < scalar $self->{type_args}->@*;
        }
    }

    for my $i (0 .. $#expected) {
        my $exp = %bindings ? $expected[$i]->substitute(\%bindings) : $expected[$i];
        return 0 unless $exp->contains($actual[$i]);
    }
    1;
}

sub free_vars ($self) {
    my %seen;
    for my $types (values $self->{variants}->%*) {
        $seen{$_} = 1 for map { $_->free_vars } @$types;
    }
    for my $arg ($self->{type_args}->@*) {
        $seen{$_} = 1 for $arg->free_vars;
    }
    # Type params are bound by this declaration, not free
    delete $seen{$_} for $self->{type_params}->@*;
    keys %seen;
}

sub substitute ($self, $bindings) {
    my %new_variants;
    for my $tag (keys $self->{variants}->%*) {
        $new_variants{$tag} = [
            map { $_->substitute($bindings) } $self->{variants}{$tag}->@*
        ];
    }
    my @new_args = map { $_->substitute($bindings) } $self->{type_args}->@*;
    __PACKAGE__->new($self->{name}, \%new_variants,
        type_params => [$self->{type_params}->@*],
        type_args   => \@new_args,
    );
}

# Create an instantiated copy with concrete type arguments
sub instantiate ($self, @args) {
    __PACKAGE__->new($self->{name}, $self->{variants},
        type_params => [$self->{type_params}->@*],
        type_args   => \@args,
    );
}

1;
