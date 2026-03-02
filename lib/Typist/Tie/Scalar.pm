package Typist::Tie::Scalar;
use v5.40;

our $VERSION = '0.01';

# Enforces type constraints on scalar assignment via Perl's tie mechanism.
# STORE validates the new value against the declared type.

sub TIESCALAR ($class, %args) {
    bless +{
        type    => $args{type},
        value   => undef,
        name    => $args{name} // '(anonymous)',
        pkg     => $args{pkg}  // '(unknown)',
        ref_key => $args{ref_key},
    }, $class;
}

sub STORE ($self, $value) {
    my $type = $self->{type};
    unless ($type->contains($value)) {
        my $got = defined $value ? "'$value'" : 'undef';
        die sprintf(
            "Typist: type error — %s expected %s, got %s\n",
            $self->{name}, $type->to_string, $got,
        );
    }
    $self->{value} = $value;
}

sub FETCH ($self) {
    $self->{value};
}

sub DESTROY ($self) {
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    if (defined $self->{ref_key}) {
        Typist::Registry->_unregister_variable($self->{ref_key});
    }
}

1;

=head1 NAME

Typist::Tie::Scalar - Runtime type enforcement via tie

=head1 SYNOPSIS

    use Typist::Tie::Scalar;

    tie my $x, 'Typist::Tie::Scalar', type => $int_type, name => '$x';
    $x = 42;    # OK
    $x = "hi";  # dies: type error

=head1 DESCRIPTION

Enforces type constraints on scalar assignment using Perl's C<tie>
mechanism. C<STORE> validates the new value against the declared type
via the type's C<contains> method. Activated when C<use Typist -runtime>
is in effect.

=head1 METHODS

=head2 TIESCALAR

    tie $var, 'Typist::Tie::Scalar', type => $type, name => '$x', pkg => 'main';

=head2 STORE

    $x = $value;  # validates against type

Dies with a type error if the value does not satisfy the declared type.

=head2 FETCH

    my $val = $x;

Returns the stored value.

=head1 SEE ALSO

L<Typist::Attribute>, L<Typist::Type>

=cut
