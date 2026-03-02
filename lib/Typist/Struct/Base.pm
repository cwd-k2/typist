package Typist::Struct::Base;
use v5.40;

our $VERSION = '0.01';

# Immutable base class for struct instances.
# Subclasses are generated at runtime by the `struct` keyword.

# Immutable update: returns a new instance with specified fields changed.
sub with ($self, %updates) {
    my $meta = $self->_typist_struct_meta;
    my %all_fields = (%{$meta->{required}}, %{$meta->{optional}});

    # Validate field names
    for my $key (keys %updates) {
        die "Unknown field '$key' for struct $meta->{name}\n"
            unless exists $all_fields{$key};
    }

    # Merge: existing values + updates
    my %new = %$self;
    @new{keys %updates} = values %updates;

    bless \%new, ref $self;
}

# Override in generated subclasses
sub _typist_struct_meta ($self) {
    die ref($self) . " must implement _typist_struct_meta()";
}

1;
