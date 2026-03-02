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
