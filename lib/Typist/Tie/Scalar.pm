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
