package Typist::Static::NarrowingEngine;
use v5.40;

our $VERSION = '0.01';

use Scalar::Util ();
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
        _recorded_blocks    => +{},
        _block_env_cache    => +{},
        _early_return_cache => +{},
    }, $class;
}

sub narrowed_vars      ($self) { $self->{_narrowed_vars} }
sub narrowed_accessors ($self) { $self->{_narrowed_accessors} }

# ── Narrowing Dispatch ─────────────────────────

# Run narrowing candidates against condition children.
# Returns ($rule_name, $negated, %narrowed) or (undef) if no rule matched.
# Handles `!`/`not` prefix: strips it and sets $negated = 1.
# Handles `&&`/`and` compound conditions: splits and accumulates.
sub _dispatch_narrowing ($self, $cond_children, $env) {
    # Handle && compound conditions: split and accumulate narrowings
    my @segments = $self->_split_at_and($cond_children);
    if (@segments > 1) {
        my (%accumulated, $first_rule, $any_negated);
        for my $segment (@segments) {
            my ($rule, $neg, %narrowing) = $self->_dispatch_narrowing($segment, $env);
            next unless $rule;
            $first_rule //= $rule;
            $any_negated ||= $neg;
            $accumulated{$_} = $narrowing{$_} for keys %narrowing;
        }
        return (undef) unless %accumulated;
        return ($first_rule, $any_negated // 0, %accumulated);
    }

    my @effective = @$cond_children;
    my $negated = 0;
    if (@effective >= 2) {
        my $first = $effective[0];
        if (($first->isa('PPI::Token::Operator') && $first->content eq '!')
            || ($first->isa('PPI::Token::Word') && $first->content eq 'not'))
        {
            $negated = 1;
            shift @effective;
        }
    }

    for my $candidate (
        [defined    => sub { $self->_narrow_defined(\@effective, $env) }],
        [isa        => sub { $self->_narrow_isa(\@effective, $env) }],
        [ref        => sub { $self->_narrow_ref(\@effective, $env) }],
        [truthiness => sub { $self->_narrow_truthiness(\@effective, $env) }],
    ) {
        my ($name, $cb) = @$candidate;
        my %try = $cb->()->%*;
        return ($name, $negated, %try) if %try;
    }
    return (undef);
}

# Split condition children at && or `and` operators into segments.
sub _split_at_and ($self, $cond_children) {
    my @segments;
    my @current;
    for my $child (@$cond_children) {
        if ($child->isa('PPI::Token::Operator')
            && ($child->content eq '&&' || $child->content eq 'and'))
        {
            push @segments, [@current] if @current;
            @current = ();
        } else {
            push @current, $child;
        }
    }
    push @segments, [@current] if @current;
    @segments;
}

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
    $self->resolve_chain_type($env, $var_name, [$field_name]);
}

# Resolve the type at the end of a multi-level accessor chain.
# e.g., resolve_chain_type($env, '$t', ['branch', 'leaf']) resolves
# $t->branch()->leaf() by walking through struct fields.
sub resolve_chain_type ($self, $env, $var_name, $chain) {
    my $type = $env->{variables}{$var_name} // return undef;

    for my $i (0 .. $#$chain) {
        my $field_name = $chain->[$i];

        # Resolve type name to concrete struct (Alias, Atom, or Var → registry lookup)
        my $resolved = $type;
        if ($self->{registry}) {
            my $name = $resolved->is_alias ? $resolved->alias_name
                     : ($resolved->is_atom || $resolved->is_var) ? $resolved->name
                     : undef;
            if ($name) {
                my $looked_up = eval { $self->{registry}->lookup_type($name) };
                $resolved = $looked_up if $looked_up && $looked_up->is_struct;
            }
        }
        return undef unless $resolved->is_struct;

        my $record = $resolved->record;
        my $req = $record->required_ref;
        my $opt = $record->optional_ref;

        if (exists $req->{$field_name}) {
            $type = $req->{$field_name};
        } elsif (exists $opt->{$field_name}) {
            $type = ($i == $#$chain)
                ? Typist::Type::Union->new(
                    $opt->{$field_name}, Typist::Type::Atom->new('Undef'),
                )
                : $opt->{$field_name};
        } else {
            return undef;
        }
    }
    $type;
}

# ── Nested Tree Env Helpers ─────────────────────

# Narrow an accessor chain in the env's narrowed_accessors tree.
# $env->{narrowed_accessors}{$var}{f1}{f2}{__type__} = $type
sub _narrow_accessor_chain ($self, $accessor, $env, $narrowed_type) {
    my $var_name = $accessor->{var_name};
    my $chain    = $accessor->{chain};
    my %acc = ($env->{narrowed_accessors} // +{})->%*;
    my $cursor = \%acc;
    $cursor = ($cursor->{$var_name} //= +{});
    for my $i (0 .. $#$chain) {
        if ($i == $#$chain) {
            $cursor->{$chain->[$i]}{__type__} = $narrowed_type;
        } else {
            $cursor = ($cursor->{$chain->[$i]} //= +{});
        }
    }
    \%acc;
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

    # Expect: Symbol, Operator(->), Word [, List, Operator(->), Word ...]
    # Method call parens (List nodes) may appear between accessor steps.
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
        # Skip method call parens: ->method() -> next
        $i++ if $i <= $#tokens && $tokens[$i]->isa('PPI::Structure::List');
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

    # Strip blessed-class prefix: `$x isa Typist::Struct::Foo` → resolve as `Foo`
    my $resolved = $self->_resolve_type($type_name);
    if (!$resolved && $type_name =~ /\ATypist::(?:Struct|Newtype)::(.+)\z/) {
        $resolved = $self->_resolve_type($1);
    }
    return +{} unless $resolved;

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

    # Recursively apply narrowing from ancestor compound blocks first,
    # so outer `if (defined($x)) { if ($flag) { ... } }` narrows $x in inner block.
    my $parent_compound = $block->parent;
    if ($parent_compound && $parent_compound->isa('PPI::Statement::Compound')) {
        my $outer = $parent_compound->parent;
        if ($outer && $outer->isa('PPI::Structure::Block')) {
            $env = $self->narrow_env_for_block($env, $parent_compound);
        }
    }

    my $cache_key = join "\0", Scalar::Util::refaddr($env), Scalar::Util::refaddr($block);
    if (exists $self->{_block_env_cache}{$cache_key}) {
        return $self->{_block_env_cache}{$cache_key};
    }

    # The block's parent must be a Compound statement (if/elsif/unless/while)
    my $compound = $block->parent;
    unless ($compound && $compound->isa('PPI::Statement::Compound')) {
        return $self->{_block_env_cache}{$cache_key} = $env;
    }

    # Determine which block we are in: then (index 0) or else (index 1+)
    my @blocks = grep { $_->isa('PPI::Structure::Block') } $compound->schildren;
    return $self->{_block_env_cache}{$cache_key} = $env unless @blocks;

    my $block_index = -1;
    for my $i (0 .. $#blocks) {
        if ($blocks[$i] == $block) {
            $block_index = $i;
            last;
        }
    }
    return $self->{_block_env_cache}{$cache_key} = $env if $block_index < 0;

    # Extract the condition that precedes this specific block.
    # For elsif chains, each block has its own preceding Condition.
    my ($condition, $is_then_block);
    my @compound_children = $compound->schildren;
    my $block_ci;  # index of this block in compound_children
    for my $i (0 .. $#compound_children) {
        next unless $compound_children[$i] == $block;
        $block_ci = $i;
        for my $j (reverse 0 .. $i - 1) {
            if ($compound_children[$j]->isa('PPI::Structure::Condition')) {
                $condition = $compound_children[$j];
                # Block is then-block if no other Block sits between condition and this block
                $is_then_block = 1;
                for my $k ($j + 1 .. $i - 1) {
                    if ($compound_children[$k]->isa('PPI::Structure::Block')) {
                        $is_then_block = 0;
                        last;
                    }
                }
                last;
            }
        }
        last;
    }
    return $self->{_block_env_cache}{$cache_key} = $env unless $condition;

    # Unwrap: Condition -> Expression -> children
    my @cond_children = $condition->schildren;
    my $expr = $cond_children[0];
    if ($expr && $expr->isa('PPI::Statement::Expression')) {
        @cond_children = $expr->schildren;
    }

    # Dispatch through narrowing rules (order matters: most specific first)
    my ($rule, $negated, %narrowing) = $self->_dispatch_narrowing(\@cond_children, $env);

    # Accessor-defined: defined($var->field) narrows the field type,
    # even when _narrow_defined returns empty (no simple variable).
    if (!$rule && $self->extract_defined_accessor(\@cond_children)) {
        $rule = 'defined';
    }

    return $self->{_block_env_cache}{$cache_key} = $env unless $rule;

    # Detect `unless` keyword — reverses narrowing polarity
    my ($keyword) = grep { $_->isa('PPI::Token::Word') } $compound->schildren;
    my $is_unless = $keyword && $keyword->content eq 'unless';

    # Then-block gets direct narrowing, else-block gets inverse
    my $apply_direct = $is_unless ? !$is_then_block : $is_then_block;

    # Negated condition (!defined, !$x, etc.) flips polarity
    $apply_direct = !$apply_direct if $negated;

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

    my $accessor_info;
    if ($apply_direct && $rule eq 'defined') {
        my $accessor = $self->extract_defined_accessor(\@cond_children);
        if ($accessor) {
            my $var_name   = $accessor->{var_name};
            my $chain      = $accessor->{chain};
            my $field_type = $self->resolve_chain_type($env, $var_name, $chain);
            my $narrowed   = $self->remove_undef_from_type($field_type);
            $accessor_info = +{ accessor => $accessor, type => $narrowed }
                if $narrowed;
        }
    }

    return $self->{_block_env_cache}{$cache_key} = $env
        unless %applied || $accessor_info;

    # Record narrowed variables for LSP visibility (once per block)
    my $block_id = Scalar::Util::refaddr($block);
    unless ($self->{_recorded_blocks}{$block_id}) {
        $self->{_recorded_blocks}{$block_id} = 1;
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
        if ($accessor_info) {
            push $self->{_narrowed_accessors}->@*, +{
                var_name    => $accessor_info->{accessor}{var_name},
                chain       => $accessor_info->{accessor}{chain},
                type        => $accessor_info->{type},
                scope_start => $block_start,
                scope_end   => $block_end,
            };
        }
    }

    my %new_vars = $env->{variables}->%*;
    $new_vars{$_} = $applied{$_} for keys %applied;
    my $new_env = +{ %$env, variables => \%new_vars };
    if ($accessor_info) {
        my $acc = $self->_narrow_accessor_chain(
            $accessor_info->{accessor}, $env, $accessor_info->{type},
        );
        $new_env->{narrowed_accessors} = $acc;
    }
    return $self->{_block_env_cache}{$cache_key} = $new_env;
}

# ── Early Return Narrowing ──────────────────────

# Scan for `return ... unless defined $var` patterns preceding the current node.
# Walks up through enclosing compound/block scopes to accumulate narrowings.
sub scan_early_returns ($self, $env, $node) {
    # Find the statement containing this node
    my $stmt = $node;
    while ($stmt && !$stmt->isa('PPI::Statement')) {
        $stmt = $stmt->parent;
    }
    return $env unless $stmt;

    my $cache_key = join "\0", Scalar::Util::refaddr($env), Scalar::Util::refaddr($stmt);
    if (exists $self->{_early_return_cache}{$cache_key}) {
        return $self->{_early_return_cache}{$cache_key};
    }

    # The statement must live inside a Block
    my $parent_block = $stmt->parent;
    unless ($parent_block && $parent_block->isa('PPI::Structure::Block')) {
        return $self->{_early_return_cache}{$cache_key} = $env;
    }

    my %narrowed_vars;
    my %narrowed_accessors;
    my $cursor_stmt = $stmt;
    my $cursor_block = $parent_block;
    while ($cursor_block) {
        my $sib = $cursor_stmt->sprevious_sibling;
        while ($sib) {
            if ($sib->isa('PPI::Statement')) {
                my %vars = $self->_statement_early_return_narrowed_vars($sib, $env)->%*;
                my %accs = $self->_statement_early_return_narrowed_accessors($sib, $env)->%*;
                $narrowed_vars{$_} //= $vars{$_} for keys %vars;
                $narrowed_accessors{$_} //= $accs{$_} for keys %accs;
            }
            $sib = $sib->sprevious_sibling;
        }

        my $compound = $cursor_block->parent;
        last unless $compound && $compound->isa('PPI::Statement::Compound');
        $cursor_stmt = $compound;
        $cursor_block = $compound->parent;
        last unless $cursor_block && $cursor_block->isa('PPI::Structure::Block');
    }

    unless (%narrowed_vars || %narrowed_accessors) {
        return $self->{_early_return_cache}{$cache_key} = $env;
    }

    # Record narrowed variables/accessors for LSP visibility (once per statement)
    my $stmt_id = Scalar::Util::refaddr($stmt);
    unless ($self->{_recorded_blocks}{$stmt_id}) {
        $self->{_recorded_blocks}{$stmt_id} = 1;
        my $fn_last     = $parent_block->last_element;
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
        for my $key (keys %narrowed_accessors) {
            my $info = $narrowed_accessors{$key};
            push $self->{_narrowed_accessors}->@*, +{
                var_name    => $info->{accessor}{var_name},
                chain       => $info->{accessor}{chain},
                type        => $info->{type},
                scope_start => $scope_start,
                scope_end   => $scope_end,
            };
        }
    }

    my %new_vars = $env->{variables}->%*;
    $new_vars{$_} = $narrowed_vars{$_} for keys %narrowed_vars;
    my $new_env = +{ %$env, variables => \%new_vars };

    # Add accessor narrowings to env for Infer to use
    if (%narrowed_accessors) {
        my $acc = ($env->{narrowed_accessors} // +{});
        for my $key (keys %narrowed_accessors) {
            my $info = $narrowed_accessors{$key};
            $acc = $self->_narrow_accessor_chain($info->{accessor}, +{ narrowed_accessors => $acc }, $info->{type});
        }
        $new_env->{narrowed_accessors} = $acc;
    }

    return $self->{_early_return_cache}{$cache_key} = $new_env;
}

# Check if statement children match: return/die/croak [exprs] unless defined $var [;]
sub _is_early_return_unless_defined ($self, $children) {
    return 0 unless @$children >= 4;
    return 0 unless $children->[0]->isa('PPI::Token::Word')
                  && ($children->[0]->content eq 'return'
                      || $children->[0]->content eq 'die'
                      || $children->[0]->content eq 'croak'
                      || $children->[0]->content eq 'exit');

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
            # Expect: Symbol -> Word [() -> Word ...]
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
                # Skip method call parens
                $j++ if $j <= $#tokens && $tokens[$j]->isa('PPI::Structure::List');
            }
            return +{ var_name => $var_name, chain => \@chain } if @chain;
        }
    }
    undef;
}

# Check if statement matches: defined($var) or/|| return/die/croak/exit
sub _is_short_circuit_defined_guard ($self, $children) {
    return 0 unless @$children >= 4;
    return 0 unless $children->[0]->isa('PPI::Token::Word')
                  && $children->[0]->content eq 'defined';

    for my $i (1 .. $#$children - 1) {
        next unless $children->[$i]->isa('PPI::Token::Operator');
        my $op = $children->[$i]->content;
        next unless $op eq '||' || $op eq 'or';

        my $rhs = $children->[$i + 1];
        return $rhs->isa('PPI::Token::Word')
            && ($rhs->content eq 'return'
                || $rhs->content eq 'die'
                || $rhs->content eq 'croak'
                || $rhs->content eq 'exit');
    }
    0;
}

sub _statement_early_return_narrowed_vars ($self, $stmt, $env) {
    my %narrowed;
    my @children = $stmt->schildren;
    if ($self->_is_early_return_unless_defined(\@children)) {
        my $var_name = $self->_early_return_var(\@children);
        if ($var_name) {
            my $var_type = $env->{variables}{$var_name};
            my $n = $self->remove_undef_from_type($var_type);
            $narrowed{$var_name} = $n if $n;
        }
    }

    # Pattern: defined($var) or die/return/croak/exit
    #          defined($var) || return/die/croak/exit
    if (!%narrowed && $self->_is_short_circuit_defined_guard(\@children)) {
        my $sym = $self->_extract_defined_symbol(\@children);
        if ($sym) {
            my $var_name = $sym->content;
            my $var_type = $env->{variables}{$var_name};
            my $n = $self->remove_undef_from_type($var_type);
            $narrowed{$var_name} = $n if $n;
        }
    }

    if ($stmt->isa('PPI::Statement::Compound')) {
        my %compound = $self->_compound_fallthrough_narrowed_vars($stmt, $env)->%*;
        $narrowed{$_} //= $compound{$_} for keys %compound;
    }

    return +{ %narrowed };
}

sub _statement_early_return_narrowed_accessors ($self, $stmt, $env) {
    my %narrowed;
    my @children = $stmt->schildren;
    if ($self->_is_early_return_unless_defined(\@children)) {
        my $accessor = $self->_early_return_accessor(\@children);
        if ($accessor) {
            my $vname      = $accessor->{var_name};
            my $chain      = $accessor->{chain};
            my $field_type = $self->resolve_chain_type($env, $vname, $chain);
            if ($field_type) {
                my $n = $self->remove_undef_from_type($field_type);
                if ($n) {
                    my $key = join("\0", $vname, @$chain);
                    $narrowed{$key} = +{
                        accessor => $accessor,
                        type     => $n,
                    };
                }
            }
        }
    }

    if ($stmt->isa('PPI::Statement::Compound')) {
        my %compound = $self->_compound_fallthrough_narrowed_accessors($stmt, $env)->%*;
        $narrowed{$_} //= $compound{$_} for keys %compound;
    }

    return +{ %narrowed };
}

sub _compound_fallthrough_narrowed_vars ($self, $compound, $env) {
    my ($condition) = grep { $_->isa('PPI::Structure::Condition') } $compound->schildren;
    return +{} unless $condition;

    my @blocks = grep { $_->isa('PPI::Structure::Block') } $compound->schildren;

    # Single-block guard: unless/if (COND) { return; }
    if (@blocks == 1 && $self->_block_is_immediate_return($blocks[0])) {
        return $self->_single_block_guard_narrowing($compound, $condition, $env);
    }

    return +{} unless @blocks >= 2;

    my ($return_idx, $flow_idx) = $self->_compound_return_and_flow_indices(@blocks);
    return +{} unless defined $return_idx && defined $flow_idx;

    my @cond_children = $condition->schildren;
    my $expr = $cond_children[0];
    @cond_children = $expr->schildren if $expr && $expr->isa('PPI::Statement::Expression');

    my ($rule, $negated, %narrowing) = $self->_dispatch_narrowing(\@cond_children, $env);
    return +{} unless $rule;

    my ($keyword) = grep { $_->isa('PPI::Token::Word') } $compound->schildren;
    my $is_unless = $keyword && $keyword->content eq 'unless';
    my $apply_direct = $is_unless ? ($flow_idx > 0) : ($flow_idx == 0);
    $apply_direct = !$apply_direct if $negated;
    if ($rule eq 'ref' && ($narrowing{_ref_op} // '') eq 'ne') {
        $apply_direct = !$apply_direct;
    }
    delete $narrowing{_ref_op};

    return +{ %narrowing } if $apply_direct;

    my %applied;
    for my $var_name (keys %narrowing) {
        my $original = $env->{variables}{$var_name};
        my %inv = $self->_inverse_narrowing($rule, $var_name, $original)->%*;
        $applied{$_} = $inv{$_} for keys %inv;
    }
    return +{ %applied };
}

sub _compound_fallthrough_narrowed_accessors ($self, $compound, $env) {
    my ($condition) = grep { $_->isa('PPI::Structure::Condition') } $compound->schildren;
    return +{} unless $condition;

    my @blocks = grep { $_->isa('PPI::Structure::Block') } $compound->schildren;
    return +{} unless @blocks >= 2;

    my ($return_idx, $flow_idx) = $self->_compound_return_and_flow_indices(@blocks);
    return +{} unless defined $return_idx && defined $flow_idx;

    my @cond_children = $condition->schildren;
    my $expr = $cond_children[0];
    @cond_children = $expr->schildren if $expr && $expr->isa('PPI::Statement::Expression');
    my $accessor = $self->extract_defined_accessor(\@cond_children) // return +{};

    my ($keyword) = grep { $_->isa('PPI::Token::Word') } $compound->schildren;
    my $is_unless = $keyword && $keyword->content eq 'unless';
    my $apply_direct = $is_unless ? ($flow_idx > 0) : ($flow_idx == 0);
    return +{} unless $apply_direct;

    my $vname      = $accessor->{var_name};
    my $chain      = $accessor->{chain};
    my $field_type = $self->resolve_chain_type($env, $vname, $chain);
    return +{} unless $field_type;
    my $n = $self->remove_undef_from_type($field_type);
    return +{} unless $n;

    my $key = join("\0", $vname, @$chain);
    return +{
        $key => +{
            accessor => $accessor,
            type     => $n,
        },
    };
}

sub _compound_return_and_flow_indices ($self, @blocks) {
    my ($return_idx, $flow_idx);
    for my $i (0 .. $#blocks) {
        if ($self->_block_is_immediate_return($blocks[$i])) {
            $return_idx = $i;
        } elsif (!defined $flow_idx) {
            $flow_idx = $i;
        }
    }
    return ($return_idx, $flow_idx);
}

sub _block_is_immediate_return ($self, $block) {
    my @stmts = grep { $_->isa('PPI::Statement') } $block->schildren;
    return 0 unless @stmts == 1;
    my @children = $stmts[0]->schildren;
    return 0 unless @children;
    return $children[0]->isa('PPI::Token::Word')
        && ($children[0]->content eq 'return'
            || $children[0]->content eq 'die'
            || $children[0]->content eq 'croak'
            || $children[0]->content eq 'exit');
}

# Handle single-block guard: unless/if (COND) { return; }
# Returns narrowing to apply after the guard statement.
sub _single_block_guard_narrowing ($self, $compound, $condition, $env) {
    my @cond_children = $condition->schildren;
    my $expr = $cond_children[0];
    @cond_children = $expr->schildren if $expr && $expr->isa('PPI::Statement::Expression');

    my ($rule, $negated, %narrowing) = $self->_dispatch_narrowing(\@cond_children, $env);
    return +{} unless $rule;

    my ($keyword) = grep { $_->isa('PPI::Token::Word') } $compound->schildren;
    my $is_unless = $keyword && $keyword->content eq 'unless';
    my $apply_direct = $is_unless ? 1 : 0;
    $apply_direct = !$apply_direct if $negated;
    if ($rule eq 'ref' && ($narrowing{_ref_op} // '') eq 'ne') {
        $apply_direct = !$apply_direct;
    }
    delete $narrowing{_ref_op};
    return +{ %narrowing } if $apply_direct;

    my %applied;
    for my $var_name (keys %narrowing) {
        my $original = $env->{variables}{$var_name};
        my %inv = $self->_inverse_narrowing($rule, $var_name, $original)->%*;
        $applied{$_} = $inv{$_} for keys %inv;
    }
    return +{ %applied };
}

# ── Accessor Narrowing Collection ────────────────
#
# Proactively scan for `if (defined($var->field))` patterns and record
# the narrowed accessor scope for LSP hover.
sub collect_accessor_narrowings ($self, $ppi_doc) {
    return unless $ppi_doc;

    # Pattern 1: if/unless compound statements
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

    # Pattern 2: ternary expressions — defined($u->field) ? expr : default
    $self->_collect_ternary_accessor_narrowings($ppi_doc);
}

sub _collect_ternary_accessor_narrowings ($self, $ppi_doc) {
    # Scan all statements for ternary patterns with defined() accessor conditions
    my $stmts = $ppi_doc->find('PPI::Statement') || [];
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;

        # Find ? operator (ternary)
        my ($q_idx, $c_idx, $q_depth);
        for my $i (0 .. $#children) {
            next unless $children[$i]->isa('PPI::Token::Operator');
            if ($children[$i]->content eq '?' && !defined $q_idx) {
                $q_idx = $i;
                $q_depth = 0;
            } elsif (defined $q_idx && $children[$i]->content eq '?') {
                $q_depth++;
            } elsif (defined $q_idx && $children[$i]->content eq ':') {
                if ($q_depth == 0) { $c_idx = $i; last }
                $q_depth--;
            }
        }
        next unless defined $q_idx && defined $c_idx;

        # Extract condition tokens before ?
        my @cond_children;
        if ($q_idx >= 2) {
            # Check for defined($var->field) pattern
            my $cond_end = $q_idx - 1;
            my $cond_start = $cond_end;
            # Walk back to find 'defined' word
            while ($cond_start > 0) {
                last if $children[$cond_start - 1]->isa('PPI::Token::Word')
                     && $children[$cond_start - 1]->content eq 'defined';
                $cond_start--;
            }
            if ($cond_start > 0) {
                $cond_start--;  # include 'defined'
                @cond_children = @children[$cond_start .. $cond_end];
            }
        }
        next unless @cond_children;

        my $accessor = $self->extract_defined_accessor(\@cond_children);
        next unless $accessor;

        # Register narrowing for the then-branch scope (same line as ternary)
        my $scope_line = $stmt->line_number;
        push $self->{_narrowed_accessors}->@*, +{
            var_name    => $accessor->{var_name},
            chain       => $accessor->{chain},
            scope_start => $scope_line,
            scope_end   => $scope_line,
        };
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
