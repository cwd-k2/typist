package Typist::Transform;
use v5.40;

our $VERSION = '0.01';

use Typist::Type::Var;
use Typist::Type::Fold;

# Replace Alias nodes whose names match declared type variable names
# with Var nodes.  Returns a new tree (no mutation).

sub aliases_to_vars ($class, $type, $var_names) {
    Typist::Type::Fold->map_type($type, sub ($node) {
        return Typist::Type::Var->new($node->alias_name)
            if $node->is_alias && $var_names->{$node->alias_name};
        $node;
    });
}

1;

=head1 NAME

Typist::Transform - Type tree transformations

=head1 SYNOPSIS

    use Typist::Transform;

    my $new_type = Typist::Transform->aliases_to_vars($type, \%var_names);

=head1 DESCRIPTION

Provides non-destructive type tree transformations. Currently offers
C<aliases_to_vars>, which replaces C<Alias> nodes matching declared
type variable names with C<Var> nodes. Used during generic declaration
processing to convert multi-character type variables.

=head1 METHODS

=head2 aliases_to_vars

    my $new = Typist::Transform->aliases_to_vars($type, \%var_names);

Returns a new type tree with matching Alias nodes replaced by Var
nodes. C<%var_names> maps variable names to truthy values.

=head1 SEE ALSO

L<Typist::Type::Fold>, L<Typist::Attribute>

=cut
