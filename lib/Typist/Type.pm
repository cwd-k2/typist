package Typist::Type;
use v5.40;

our $VERSION = '0.01';

use overload
    '|'    => \&_op_union,
    '&'    => \&_op_intersection,
    '""'   => sub ($self, @) { $self->to_string },
    'bool' => sub { 1 },
    fallback => 1;

# Abstract base class for all type objects.
# Every type is an immutable value object sharing this interface.

sub name        { die ref(shift) . " must implement name()" }
sub to_string   { die ref(shift) . " must implement to_string()" }
sub equals      { die ref(shift) . " must implement equals()" }
sub contains    { die ref(shift) . " must implement contains()" }
sub free_vars   { die ref(shift) . " must implement free_vars()" }
sub substitute  { die ref(shift) . " must implement substitute()" }

sub is_atom         { 0 }
sub is_param        { 0 }
sub is_union        { 0 }
sub is_intersection { 0 }
sub is_func         { 0 }
sub is_struct       { 0 }
sub is_var          { 0 }
sub is_alias        { 0 }
sub is_literal      { 0 }
sub is_newtype      { 0 }
sub is_row          { 0 }
sub is_eff          { 0 }
sub is_data         { 0 }
sub is_quantified   { 0 }

# Coerce a value into a Type object: blessed Types pass through, strings are parsed.
sub coerce ($class, $expr) {
    return $expr if ref $expr && $expr->isa('Typist::Type');
    require Typist::Parser;
    Typist::Parser->parse($expr);
}

# ── Operator Overloads ──────────────────────────

sub _op_union {
    my ($self, $other) = @_;
    require Typist::Type::Union;
    $other = Typist::Type->coerce($other) unless ref $other && $other->isa('Typist::Type');
    Typist::Type::Union->new($self, $other);
}

sub _op_intersection {
    my ($self, $other) = @_;
    require Typist::Type::Intersection;
    $other = Typist::Type->coerce($other) unless ref $other && $other->isa('Typist::Type');
    Typist::Type::Intersection->new($self, $other);
}

1;
