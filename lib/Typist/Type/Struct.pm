package Typist::Type::Struct;
use v5.40;

our $VERSION = '0.01';

use parent 'Typist::Type';
use Scalar::Util qw(blessed reftype);
use List::Util   'all';

# Nominal struct type: named, blessed, immutable.
# Wraps a Record for field definitions but imposes a nominal identity barrier.

sub new ($class, %args) {
    bless +{
        name        => $args{name},
        record      => $args{record},   # Typist::Type::Record
        package     => $args{package},  # blessed package name
        type_params => $args{type_params} // [],
        type_args   => $args{type_args}   // [],
        type_bounds => $args{type_bounds} // {},  # { T => 'Ord' } display strings
    }, $class;
}

sub name        ($self) { $self->{name} }
sub record      ($self) { $self->{record} }
sub package     ($self) { $self->{package} }
sub type_params ($self) { $self->{type_params}->@* }
sub type_args   ($self) { $self->{type_args}->@* }

# Delegate field accessors to the inner Record
sub fields          ($self) { $self->{record}->fields }
sub required_fields ($self) { $self->{record}->required_fields }
sub optional_fields ($self) { $self->{record}->optional_fields }
sub required_ref    ($self) { $self->{record}->required_ref }
sub optional_ref    ($self) { $self->{record}->optional_ref }
sub field_ref       ($self) { $self->{record}->field_ref }

# Type predicates
sub is_struct ($self) { 1 }

sub to_string ($self) {
    my $base = $self->{name};
    if ($self->{type_args}->@*) {
        $base .= '[' . join(', ', map { $_->to_string } $self->{type_args}->@*) . ']';
    } elsif ($self->{type_params}->@*) {
        my @parts;
        for my $p ($self->{type_params}->@*) {
            my $b = $self->{type_bounds}{$p};
            push @parts, $b ? "$p: $b" : $p;
        }
        $base .= '[' . join(', ', @parts) . ']';
    }
    $base;
}

sub equals ($self, $other) {
    return 0 unless $other->is_struct;
    return 0 unless $self->{name} eq $other->name;

    my @sa = $self->{type_args}->@*;
    my @oa = $other->type_args;
    return 0 if @sa != @oa;
    for my $i (0 .. $#sa) {
        return 0 unless $sa[$i]->equals($oa[$i]);
    }
    1;
}

sub contains ($self, $value) {
    return 0 unless blessed($value) && $value->isa($self->{package});

    # If we have concrete type_args, substitute into record for validation
    my $record = $self->{record};
    if ($self->{type_args}->@* && $self->{type_params}->@*) {
        my %bindings;
        for my $i (0 .. $#{$self->{type_params}}) {
            $bindings{$self->{type_params}[$i]} = $self->{type_args}[$i]
                if $i < scalar $self->{type_args}->@*;
        }
        $record = $record->substitute(\%bindings) if %bindings;
    }

    $record->contains(+{ %$value });
}

sub free_vars ($self) {
    my %seen;
    $seen{$_} = 1 for $self->{record}->free_vars;
    for my $arg ($self->{type_args}->@*) {
        $seen{$_} = 1 for $arg->free_vars;
    }
    # Type params are bound by this declaration, not free
    delete $seen{$_} for $self->{type_params}->@*;
    keys %seen;
}

sub substitute ($self, $bindings) {
    my $new_record = $self->{record}->substitute($bindings);
    my @new_args = map { $_->substitute($bindings) } $self->{type_args}->@*;
    __PACKAGE__->new(
        name        => $self->{name},
        record      => $new_record,
        package     => $self->{package},
        type_params => [$self->{type_params}->@*],
        type_args   => \@new_args,
        type_bounds => $self->{type_bounds},
    );
}

# Create an instantiated copy with concrete type arguments
sub instantiate ($self, @args) {
    __PACKAGE__->new(
        name        => $self->{name},
        record      => $self->{record},
        package     => $self->{package},
        type_params => [$self->{type_params}->@*],
        type_args   => \@args,
        type_bounds => $self->{type_bounds},
    );
}

1;

=head1 NAME

Typist::Type::Struct - Nominal struct type

=head1 SYNOPSIS

    use Typist::Type::Struct;

    my $st = Typist::Type::Struct->new(
        name    => 'Point',
        record  => $record_type,
        package => 'MyApp::Point',
    );

=head1 DESCRIPTION

A nominal wrapper over L<Typist::Type::Record>. Struct types have
name-based identity: C<StructA E<lt>: StructB> only if same name.
Struct is a subtype of a matching Record (structural compatibility),
but Record is never a subtype of Struct (nominal barrier).

=head1 ABSTRACT INTERFACE

Inherits from L<Typist::Type> and implements: C<is_struct> (returns 1),
C<name>, C<to_string>, C<equals>, C<contains>, C<free_vars>,
C<substitute>.

=head2 record

    my $rec = $struct->record;

Returns the underlying L<Typist::Type::Record>.

=head2 package

    my $pkg = $struct->package;

Returns the blessed package name.

=head1 SEE ALSO

L<Typist::Type>, L<Typist::Type::Record>, L<Typist::Struct::Base>

=cut
