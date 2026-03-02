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
        name    => $args{name},
        record  => $args{record},   # Typist::Type::Record
        package => $args{package},  # blessed package name
    }, $class;
}

sub name    ($self) { $self->{name} }
sub record  ($self) { $self->{record} }
sub package ($self) { $self->{package} }

# Delegate field accessors to the inner Record
sub required_fields ($self) { $self->{record}->required_fields }
sub optional_fields ($self) { $self->{record}->optional_fields }
sub required_ref    ($self) { $self->{record}->required_ref }
sub optional_ref    ($self) { $self->{record}->optional_ref }
sub field_ref       ($self) { $self->{record}->field_ref }

# Type predicates
sub is_struct ($self) { 1 }

sub to_string ($self) { $self->{name} }

sub equals ($self, $other) {
    return 0 unless $other->is_struct;
    $self->{name} eq $other->name;
}

sub contains ($self, $value) {
    return 0 unless blessed($value) && $value->isa($self->{package});
    # Field validation delegated to the record
    $self->{record}->contains(+{ %$value });
}

sub free_vars ($self) {
    $self->{record}->free_vars;
}

sub substitute ($self, $bindings) {
    my $new_record = $self->{record}->substitute($bindings);
    __PACKAGE__->new(
        name    => $self->{name},
        record  => $new_record,
        package => $self->{package},
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
