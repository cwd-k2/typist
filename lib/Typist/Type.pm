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
sub is_record       { 0 }
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

__END__

=head1 NAME

Typist::Type - Abstract base class for all type objects

=head1 SYNOPSIS

    use Typist::Type;

    # Coerce a string into a type object
    my $type = Typist::Type->coerce('Int | Str');

    # Operator overloading (via Typist::DSL)
    use Typist::DSL;
    my $union = Int | Str;          # Union type
    my $inter = Readable & Writable; # Intersection type
    say "$union";                    # Stringify: "Int | Str"

=head1 DESCRIPTION

Typist::Type is the abstract base class for all type objects in the
Typist type system. Every type node is an immutable value object that
implements a common interface for structural operations.

The class provides operator overloading for concise type construction:
C<|> produces union types, C<&> produces intersection types, and C<"">
invokes C<to_string>.

=head1 ABSTRACT INTERFACE

Subclasses must implement all of the following methods:

=over 4

=item B<name> - Returns the type name (identifier for named types, C<to_string> for compound types)

=item B<to_string> - Returns a human-readable string representation

=item B<equals>($other) - Structural equality comparison

=item B<contains>($value) - Runtime value membership test

=item B<free_vars> - Returns a list of unbound type variable names

=item B<substitute>(\%bindings) - Returns a new type with variables substituted

=back

=head1 TYPE PREDICATES

Each predicate returns false by default; the corresponding subclass
overrides it to return true:

    is_atom  is_param  is_union  is_intersection  is_func
    is_record  is_var  is_alias  is_literal  is_newtype
    is_row  is_eff  is_data  is_quantified

=head1 CLASS METHODS

=head2 coerce

    my $type = Typist::Type->coerce($expr);

Coerce a value into a type object. Blessed L<Typist::Type> objects pass
through unchanged; strings are parsed via L<Typist::Parser>.

=head1 SEE ALSO

L<Typist::Parser>, L<Typist::DSL>, L<Typist::Subtype>

=cut
