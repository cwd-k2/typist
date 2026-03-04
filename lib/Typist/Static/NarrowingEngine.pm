package Typist::Static::NarrowingEngine;
use v5.40;

our $VERSION = '0.01';

use Typist::Parser;
use Typist::Subtype;
use Typist::Type::Atom;
use Typist::Type::Union;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        registry            => $args{registry},
        _narrowed_vars      => [],
        _narrowed_accessors => [],
        _last_narrowed_type => +{},
    }, $class;
}

sub narrowed_vars      ($self) { $self->{_narrowed_vars} }
sub narrowed_accessors ($self) { $self->{_narrowed_accessors} }

# ── Type Resolution Helper ──────────────────────

sub _resolve_type ($self, $expr) {
    return undef unless defined $expr;
    my $parsed = eval { Typist::Parser->parse($expr) };
    return undef if $@;

    if ($parsed->is_alias) {
        my $resolved = $self->{registry}->lookup_type($parsed->alias_name);
        return $resolved if $resolved;
    }

    $parsed;
}

# ── Accessor Type Resolution ────────────────────

# Resolve the type of a struct field accessor: $var->field.
# Returns the field type or undef.
sub resolve_accessor_type ($self, $env, $var_name, $field_name) {
    my $var_type = $env->{variables}{$var_name} // return undef;

    # Resolve aliases (e.g. Product → Struct)
    my $resolved = $var_type;
    if ($resolved->is_alias && $self->{registry}) {
        my $looked_up = $self->{registry}->lookup_type($resolved->alias_name);
        $resolved = $looked_up if $looked_up;
    }
    return undef unless $resolved->is_struct;

    my $record = $resolved->record;
    my $req = $record->required_ref;
    my $opt = $record->optional_ref;

    return $req->{$field_name} if exists $req->{$field_name};
    if (exists $opt->{$field_name}) {
        return Typist::Type::Union->new(
            $opt->{$field_name}, Typist::Type::Atom->new('Undef'),
        );
    }
    undef;
}

# ── Undef Removal ───────────────────────────────

# Remove Undef from a Union type, returning the narrowed type or undef if no change.
sub remove_undef_from_type ($self, $type) {
    return undef unless $type && $type->is_union;

    my @non_undef = grep {
        !($_->is_atom && $_->name eq 'Undef')
    } $type->members;

    # Nothing removed — no narrowing needed
    return undef if @non_undef == scalar($type->members);

    @non_undef == 1
        ? $non_undef[0]
        : Typist::Type::Union->new(@non_undef);
}

# ── Pattern Extractors ──────────────────────────

# Extract a Symbol node from a `defined(...)` or `defined $x` pattern.
sub _extract_defined_symbol ($self, $cond_children) {
    return undef unless @$cond_children >= 2;
    return undef unless $cond_children->[0]->isa('PPI::Token::Word')
                     && $cond_children->[0]->content eq 'defined';

    my $list = $cond_children->[1];

    if ($list->isa('PPI::Structure::List')) {
        my @list_children = grep { $_->isa('PPI::Statement::Expression') } $list->schildren;
        if (@list_children) {
            my @exprs = $list_children[0]->schildren;
            return $exprs[0] if @exprs && $exprs[0]->isa('PPI::Token::Symbol');
        }
    } elsif ($list->isa('PPI::Token::Symbol')) {
        return $list;
    }

    undef;
}

# Extract accessor chain from `defined($var->field)` or `defined $var->field`.
# Returns { var_name => '$x', chain => ['field'] } or undef.
sub extract_defined_accessor ($self, $cond_children) {
    return undef unless @$cond_children >= 2;
    return undef unless $cond_children->[0]->isa('PPI::Token::Word')
                     && $cond_children->[0]->content eq 'defined';

    # Collect the tokens after 'defined' — either inside parens or bare
    my @tokens;
    my $second = $cond_children->[1];

    if ($second->isa('PPI::Structure::List')) {
        my @exprs = grep { $_->isa('PPI::Statement::Expression') } $second->schildren;
        @tokens = $exprs[0]->schildren if @exprs;
    } else {
        @tokens = @$cond_children[1 .. $#$cond_children];
    }

    # Expect: Symbol, Operator(->), Word [, Operator(->), Word ...]
    return undef unless @tokens >= 3;
    return undef unless $tokens[0]->isa('PPI::Token::Symbol');

    my $var_name = $tokens[0]->content;
    my @chain;

    my $i = 1;
    while ($i + 1 <= $#tokens) {
        last unless $tokens[$i]->isa('PPI::Token::Operator')
                 && $tokens[$i]->content eq '->';
        last unless $tokens[$i + 1]->isa('PPI::Token::Word');
        push @chain, $tokens[$i + 1]->content;
        $i += 2;
    }

    return undef unless @chain;
    +{ var_name => $var_name, chain => \@chain };
}

# ── Narrowing Rules ─────────────────────────────

# Rule: `defined($x)` narrows T | Undef to T.
# Returns { var_name => narrowed_type } or empty hash.
sub _narrow_defined ($self, $cond_children, $env) {
    my $var_symbol = $self->_extract_defined_symbol($cond_children) // return +{};
    my $var_name = $var_symbol->content;
    my $var_type = $env->{variables}{$var_name};
    my $narrowed = $self->remove_undef_from_type($var_type) // return +{};
    +{ $var_name => $narrowed };
}

# Rule: bare variable truthiness `if ($x)` narrows T | Undef to T.
# Returns { var_name => narrowed_type } or empty hash.
sub _narrow_truthiness ($self, $cond_children, $env) {
    # Exactly one child that is a Symbol
    return +{} unless @$cond_children == 1;
    return +{} unless $cond_children->[0]->isa('PPI::Token::Symbol');

    my $var_name = $cond_children->[0]->content;
    my $var_type = $env->{variables}{$var_name};
    my $narrowed = $self->remove_undef_from_type($var_type) // return +{};
    +{ $var_name => $narrowed };
}

# Shared ref() type map and resolution logic.
my %REF_MAP = (
    HASH    => 'HashRef[Any]',
    ARRAY   => 'ArrayRef[Any]',
    SCALAR  => 'Ref[Any]',
    CODE    => 'Ref[Any]',
    REF     => 'Ref[Any]',
    Regexp  => 'Ref[Any]',
    GLOB    => 'Ref[Any]',
    IO      => 'Ref[Any]',
    VSTRING => 'Str',
);

sub _narrow_ref_resolve ($self, $var_name, $op_str, $ref_string) {
    my %result;

    my $type_expr;
    if (exists $REF_MAP{$ref_string}) {
        $type_expr = $REF_MAP{$ref_string};
    } else {
        # Blessed object: try to resolve as struct/type name
        my $resolved = $self->_resolve_type($ref_string);
        return +{} unless $resolved;
        $type_expr = undef;
        %result = ($var_name => $resolved);
    }

    unless (%result) {
        my $narrowed = $self->_resolve_type($type_expr) // return +{};
        %result = ($var_name => $narrowed);
    }

    # Attach operator metadata for ne handling
    $result{_ref_op} = $op_str if $op_str ne 'eq';

    +{%result};
}

# Rule: `ref($x) eq 'TYPE'` or `ref $x eq 'TYPE'` narrows $x.
# Maps: HASH → HashRef[Any], ARRAY → ArrayRef[Any], SCALAR → Ref[Any], etc.
# Blessed class names are resolved via registry.
sub _narrow_ref ($self, $cond_children, $env) {
    return +{} unless @$cond_children >= 3;

    my $ref_word = $cond_children->[0];
    return +{} unless $ref_word->isa('PPI::Token::Word') && $ref_word->content eq 'ref';

    my ($var_name, $op_idx);

    # Path A: ref($x) — Word('ref') List(Symbol) ...
    if ($cond_children->[1]->isa('PPI::Structure::List')) {
        my $list = $cond_children->[1];
        my @inner = $list->schildren;
        my $expr = $inner[0];
        @inner = $expr->schildren if $expr && $expr->isa('PPI::Statement::Expression');
        return +{} unless @inner == 1 && $inner[0]->isa('PPI::Token::Symbol');
        $var_name = $inner[0]->content;
        $op_idx = 2;
    }
    # Path B: ref $x — Word('ref') Symbol('$x') ...
    elsif ($cond_children->[1]->isa('PPI::Token::Symbol')) {
        $var_name = $cond_children->[1]->content;
        $op_idx = 2;
    }
    else {
        return +{};
    }

    return +{} unless @$cond_children > $op_idx + 1;

    my $op = $cond_children->[$op_idx];
    return +{} unless $op->isa('PPI::Token::Operator') && ($op->content eq 'eq' || $op->content eq 'ne');
    my $op_str = $op->content;

    my $quote_node = $cond_children->[$op_idx + 1];

    # The RHS can be a Quote literal or a variable
    my $ref_string;
    if ($quote_node->isa('PPI::Token::Quote')) {
        $ref_string = $quote_node->string;
    } elsif ($quote_node->isa('PPI::Token::Symbol')) {
        # Variable comparison: resolve from env to Literal string
        my $var_type = $env->{variables}{$quote_node->content};
        if ($var_type && $var_type->is_literal && $var_type->base_type eq 'Str') {
            $ref_string = $var_type->value;
        } else {
            return +{};  # Unknown variable value → gradual skip
        }
    } else {
        return +{};
    }

    $self->_narrow_ref_resolve($var_name, $op_str, $ref_string);
}

# Rule: `$x isa Type` narrows $x to Type.
# Returns { var_name => narrowed_type } or empty hash.
sub _narrow_isa ($self, $cond_children, $env) {
    return +{} unless @$cond_children >= 3;
    return +{} unless $cond_children->[0]->isa('PPI::Token::Symbol');

    my $isa_token = $cond_children->[1];
    return +{} unless ($isa_token->isa('PPI::Token::Operator') || $isa_token->isa('PPI::Token::Word'))
                    && $isa_token->content eq 'isa';

    my $type_token = $cond_children->[2];
    return +{} unless $type_token->isa('PPI::Token::Word');

    my $var_name  = $cond_children->[0]->content;
    my $type_name = $type_token->content;
    my $resolved  = $self->_resolve_type($type_name) // return +{};

    +{ $var_name => $resolved };
}

# Compute inverse narrowing for else-blocks.
# For `defined`: variable is Undef.
# For `ref`/`isa` with Union: subtract narrowed type from Union members.
# For truthiness: no useful inverse, return empty.
sub _inverse_narrowing ($self, $rule, $var_name, $original_type) {
    if ($rule eq 'defined') {
        return +{ $var_name => Typist::Type::Atom->new('Undef') };
    }

    # ref/isa inverse: subtract narrowed type from Union
    if (($rule eq 'ref' || $rule eq 'isa') && $original_type && $original_type->is_union) {
        my $narrowed = $self->{_last_narrowed_type}{$var_name};
        if ($narrowed) {
            my @remaining = grep {
                !$narrowed->equals($_)
                && !Typist::Subtype->is_subtype($_, $narrowed, registry => $self->{registry})
            } $original_type->members;

            if (@remaining == 1) {
                return +{ $var_name => $remaining[0] };
            } elsif (@remaining > 1) {
                return +{ $var_name => Typist::Type::Union->new(@remaining) };
            }
        }
    }

    +{};
}

# ── Block Narrowing ─────────────────────────────

# Narrow the env based on control flow guards surrounding $node.
# Dispatches through narrowing rules and supports both then- and else-blocks.
sub narrow_env_for_block ($self, $env, $node) {
    # Walk up to the nearest enclosing Block
    my $block = $node;
    while ($block && !$block->isa('PPI::Structure::Block')) {
        $block = $block->parent;
    }
    return $env unless $block;

    # The block's parent must be a Compound statement (if/elsif/unless/while)
    my $compound = $block->parent;
    return $env unless $compound && $compound->isa('PPI::Statement::Compound');

    # Determine which block we are in: then (index 0) or else (index 1+)
    my @blocks = grep { $_->isa('PPI::Structure::Block') } $compound->schildren;
    return $env unless @blocks;

    my $block_index = -1;
    for my $i (0 .. $#blocks) {
        if ($blocks[$i] == $block) {
            $block_index = $i;
            last;
        }
    }
    return $env if $block_index < 0;

    # Extract the condition
    my ($condition) = grep { $_->isa('PPI::Structure::Condition') } $compound->schildren;
    return $env unless $condition;

    # Unwrap: Condition -> Expression -> children
    my @cond_children = $condition->schildren;
    my $expr = $cond_children[0];
    if ($expr && $expr->isa('PPI::Statement::Expression')) {
        @cond_children = $expr->schildren;
    }

    # Dispatch through narrowing rules (order matters: most specific first)
    my %narrowing;
    my $rule;

    my %try_defined = $self->_narrow_defined(\@cond_children, $env)->%*;
    if (%try_defined) {
        %narrowing = %try_defined;
        $rule = 'defined';
    }

    unless ($rule) {
        my %try_isa = $self->_narrow_isa(\@cond_children, $env)->%*;
        if (%try_isa) {
            %narrowing = %try_isa;
            $rule = 'isa';
        }
    }

    unless ($rule) {
        my %try_ref = $self->_narrow_ref(\@cond_children, $env)->%*;
        if (%try_ref) {
            %narrowing = %try_ref;
            $rule = 'ref';
        }
    }

    unless ($rule) {
        my %try_truth = $self->_narrow_truthiness(\@cond_children, $env)->%*;
        if (%try_truth) {
            %narrowing = %try_truth;
            $rule = 'truthiness';
        }
    }

    return $env unless $rule;

    # Detect `unless` keyword — reverses narrowing polarity
    my ($keyword) = grep { $_->isa('PPI::Token::Word') } $compound->schildren;
    my $is_unless = $keyword && $keyword->content eq 'unless';

    # For `if`:     block 0 = then (direct), block 1+ = else (inverse)
    # For `unless`: block 0 = body (inverse), block 1+ = else (direct)
    my $apply_direct = $is_unless ? ($block_index > 0) : ($block_index == 0);

    # `ne` operator in ref() flips the polarity
    if ($rule eq 'ref' && ($narrowing{_ref_op} // '') eq 'ne') {
        $apply_direct = !$apply_direct;
    }
    delete $narrowing{_ref_op};

    # Save narrowed types for inverse narrowing (ref/isa with Union)
    for my $var_name (keys %narrowing) {
        $self->{_last_narrowed_type}{$var_name} = $narrowing{$var_name};
    }

    # Compute the narrowed variable set based on polarity
    my %applied;
    if ($apply_direct) {
        %applied = %narrowing;
    } else {
        for my $var_name (keys %narrowing) {
            my $original = $env->{variables}{$var_name};
            my %inv = $self->_inverse_narrowing($rule, $var_name, $original)->%*;
            $applied{$_} = $inv{$_} for keys %inv;
        }
    }

    return $env unless %applied;

    # Record narrowed variables for LSP visibility
    my $block_start = $block->line_number;
    my $block_last  = $block->last_element;
    my $block_end   = $block_last ? $block_last->line_number : $block_start;
    for my $var_name (keys %applied) {
        push $self->{_narrowed_vars}->@*, +{
            name        => $var_name,
            type        => $applied{$var_name},
            scope_start => $block_start,
            scope_end   => $block_end,
        };
    }

    my %new_vars = $env->{variables}->%*;
    $new_vars{$_} = $applied{$_} for keys %applied;
    +{ %$env, variables => \%new_vars };
}

# ── Early Return Narrowing ──────────────────────

# Scan for `return ... unless defined $var` patterns before the current node's
# containing statement. Each such pattern narrows the env by removing Undef.
sub scan_early_returns ($self, $env, $node) {
    # Find the statement containing this node
    my $stmt = $node;
    while ($stmt && !$stmt->isa('PPI::Statement')) {
        $stmt = $stmt->parent;
    }
    return $env unless $stmt;

    # The statement must live inside a Block
    my $parent_block = $stmt->parent;
    return $env unless $parent_block && $parent_block->isa('PPI::Structure::Block');

    # Walk preceding sibling statements
    my %narrowed_vars;
    my %narrowed_accessors;
    my $sib = $stmt->sprevious_sibling;
    while ($sib) {
        if ($sib->isa('PPI::Statement')) {
            my @children = $sib->schildren;
            # Match: return [expr] unless defined $var
            if ($self->_is_early_return_unless_defined(\@children)) {
                my $var_name = $self->_early_return_var(\@children);
                if ($var_name) {
                    my $var_type = $env->{variables}{$var_name};
                    my $narrowed = $self->remove_undef_from_type($var_type);
                    $narrowed_vars{$var_name} = $narrowed if $narrowed;
                } else {
                    # Try accessor chain: return ... unless defined($var->accessor)
                    my $accessor = $self->_early_return_accessor(\@children);
                    if ($accessor && @{$accessor->{chain}} == 1) {
                        my $vname = $accessor->{var_name};
                        my $field = $accessor->{chain}[0];
                        my $field_type = $self->resolve_accessor_type($env, $vname, $field);
                        if ($field_type) {
                            my $narrowed = $self->remove_undef_from_type($field_type);
                            if ($narrowed) {
                                $narrowed_accessors{"$vname\0$field"} = +{
                                    var_name => $vname, accessor => $field,
                                    type => $narrowed,
                                };
                            }
                        }
                    }
                }
            }
        }
        $sib = $sib->sprevious_sibling;
    }

    return $env unless %narrowed_vars || %narrowed_accessors;

    # Record narrowed variables for LSP visibility
    my $fn_block = $parent_block;
    my $fn_last  = $fn_block->last_element;
    my $scope_start = $stmt->line_number;
    my $scope_end   = $fn_last ? $fn_last->line_number : $scope_start;
    for my $var_name (keys %narrowed_vars) {
        push $self->{_narrowed_vars}->@*, +{
            name        => $var_name,
            type        => $narrowed_vars{$var_name},
            scope_start => $scope_start,
            scope_end   => $scope_end,
        };
    }

    my %new_vars = $env->{variables}->%*;
    $new_vars{$_} = $narrowed_vars{$_} for keys %narrowed_vars;
    my $new_env = +{ %$env, variables => \%new_vars };

    # Add accessor narrowings to env for Infer to use
    if (%narrowed_accessors) {
        my %acc = ($env->{narrowed_accessors} // +{})->%*;
        for my $key (keys %narrowed_accessors) {
            my $info = $narrowed_accessors{$key};
            $acc{$info->{var_name}}{$info->{accessor}} = $info->{type};
        }
        $new_env->{narrowed_accessors} = \%acc;

        # Record for LSP visibility
        for my $key (keys %narrowed_accessors) {
            my $info = $narrowed_accessors{$key};
            push $self->{_narrowed_accessors}->@*, +{
                var_name    => $info->{var_name},
                chain       => [$info->{accessor}],
                type        => $info->{type},
                scope_start => $scope_start,
                scope_end   => $scope_end,
            };
        }
    }

    $new_env;
}

# Check if statement children match: return [exprs] unless defined $var [;]
sub _is_early_return_unless_defined ($self, $children) {
    return 0 unless @$children >= 4;
    return 0 unless $children->[0]->isa('PPI::Token::Word')
                  && $children->[0]->content eq 'return';

    # Find 'unless' token — it can be at various positions depending on
    # whether there is a return value expression
    for my $i (1 .. $#$children - 2) {
        if ($children->[$i]->isa('PPI::Token::Word')
            && $children->[$i]->content eq 'unless'
            && $children->[$i + 1]->isa('PPI::Token::Word')
            && $children->[$i + 1]->content eq 'defined')
        {
            return 1;
        }
    }
    0;
}

# Extract the variable name from a `return ... unless defined $var` statement.
sub _early_return_var ($self, $children) {
    for my $i (1 .. $#$children - 2) {
        if ($children->[$i]->isa('PPI::Token::Word')
            && $children->[$i]->content eq 'unless'
            && $children->[$i + 1]->isa('PPI::Token::Word')
            && $children->[$i + 1]->content eq 'defined')
        {
            # The variable follows `defined` — either directly or inside a list
            my $next = $children->[$i + 2];
            if ($next->isa('PPI::Token::Symbol')) {
                return $next->content;
            }
            if ($next->isa('PPI::Structure::List')) {
                my @lc = grep { $_->isa('PPI::Statement::Expression') } $next->schildren;
                if (@lc) {
                    my @exprs = $lc[0]->schildren;
                    # Only match bare $var, not accessor chains like $var->field
                    return $exprs[0]->content
                        if @exprs == 1 && $exprs[0]->isa('PPI::Token::Symbol');
                }
            }
        }
    }
    undef;
}

# Extract accessor chain from `return ... unless defined($var->accessor)`.
# Returns { var_name => '$x', chain => ['field'] } or undef.
sub _early_return_accessor ($self, $children) {
    for my $i (1 .. $#$children - 2) {
        if ($children->[$i]->isa('PPI::Token::Word')
            && $children->[$i]->content eq 'unless'
            && $children->[$i + 1]->isa('PPI::Token::Word')
            && $children->[$i + 1]->content eq 'defined')
        {
            my $next = $children->[$i + 2];
            my @tokens;
            if ($next->isa('PPI::Structure::List')) {
                my @lc = grep { $_->isa('PPI::Statement::Expression') } $next->schildren;
                @tokens = $lc[0]->schildren if @lc;
            } else {
                @tokens = @$children[$i + 2 .. $#$children];
            }
            # Expect: Symbol -> Word [-> Word ...]
            next unless @tokens >= 3;
            next unless $tokens[0]->isa('PPI::Token::Symbol');
            my $var_name = $tokens[0]->content;
            my @chain;
            my $j = 1;
            while ($j + 1 <= $#tokens) {
                last unless $tokens[$j]->isa('PPI::Token::Operator')
                         && $tokens[$j]->content eq '->';
                last unless $tokens[$j + 1]->isa('PPI::Token::Word');
                push @chain, $tokens[$j + 1]->content;
                $j += 2;
            }
            return +{ var_name => $var_name, chain => \@chain } if @chain;
        }
    }
    undef;
}

# ── Accessor Narrowing Collection ────────────────
#
# Proactively scan for `if (defined($var->field))` patterns and record
# the narrowed accessor scope for LSP hover.
sub collect_accessor_narrowings ($self, $ppi_doc) {
    return unless $ppi_doc;
    my $compounds = $ppi_doc->find('PPI::Statement::Compound') || [];

    for my $compound (@$compounds) {
        my ($keyword) = grep { $_->isa('PPI::Token::Word') } $compound->schildren;
        next unless $keyword;
        my $kw = $keyword->content;
        next unless $kw eq 'if' || $kw eq 'unless';

        my ($condition) = grep { $_->isa('PPI::Structure::Condition') } $compound->schildren;
        next unless $condition;

        my @cond_children = $condition->schildren;
        my $expr = $cond_children[0];
        if ($expr && $expr->isa('PPI::Statement::Expression')) {
            @cond_children = $expr->schildren;
        }

        my $accessor = $self->extract_defined_accessor(\@cond_children);
        next unless $accessor;

        my $is_unless = $kw eq 'unless';
        my @blocks = grep { $_->isa('PPI::Structure::Block') } $compound->schildren;

        for my $i (0 .. $#blocks) {
            my $apply = $is_unless ? ($i > 0) : ($i == 0);
            next unless $apply;

            my $block       = $blocks[$i];
            my $block_start = $block->line_number;
            my $block_last  = $block->last_element;
            my $block_end   = $block_last ? $block_last->line_number : $block_start;

            push $self->{_narrowed_accessors}->@*, +{
                var_name    => $accessor->{var_name},
                chain       => $accessor->{chain},
                scope_start => $block_start,
                scope_end   => $block_end,
            };
        }
    }
}

1;

=head1 NAME

Typist::Static::NarrowingEngine - Type narrowing rules for control flow analysis

=head1 SYNOPSIS

    use Typist::Static::NarrowingEngine;

    my $engine = Typist::Static::NarrowingEngine->new(
        registry => $registry,
    );

    my $narrowed_env = $engine->narrow_env_for_block($env, $node);
    my $narrowed_env = $engine->scan_early_returns($env, $node);
    $engine->collect_accessor_narrowings($ppi_doc);

=head1 DESCRIPTION

Encapsulates type narrowing rules: C<defined>, truthiness, C<ref>,
C<isa>, and early-return patterns. Given a PPI node and a type
environment, produces a narrowed environment with more precise types.

Records narrowing results for LSP visibility (hover, inlay hints).

=head1 SEE ALSO

L<Typist::Static::TypeChecker>, L<Typist::Subtype>

=cut
