package Typist::Transform;
use v5.40;

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
