package Typist::Static::Infer;
use v5.40;

our $_CALLBACK_CTX;  # shared with main Infer.pm

# ── Higher-Order Function & Anonymous Sub Inference ─
#
# map/grep/sort with block inference, anonymous sub bidirectional
# inference, callback parameter extraction and env enrichment.

sub _infer_map_grep_sort ($word, $env, $expected = undef) {
    my $name = $word->content;
    my $next = $word->snext_sibling;
    return undef unless $next && $next->isa('PPI::Structure::Block');

    my $block = $next;

    # Infer source list element type from siblings after the block
    my $elem_type = _infer_source_element_type_after($block, $env);

    # Record $_ binding as callback param for LSP visibility.
    # sort uses $a/$b, not $_ — skip callback param registration for sort.
    if ($elem_type && $name ne 'sort') {
        my $block_line  = $block->line_number;
        my $block_last  = $block->last_element;
        my $block_end   = $block_last ? $block_last->line_number : $block_line;
        my $dedup_key   = '$_:' . $block_line;
        unless ($_CALLBACK_CTX->{seen}{$dedup_key}++) {
            my ($topic_line, $topic_col) = ($block_line, $block->column_number + 2);
            my $magics = $block->find('PPI::Token::Magic');
            if ($magics) {
                for my $m (@$magics) {
                    if ($m->content eq '$_') {
                        ($topic_line, $topic_col) = ($m->line_number, $m->column_number);
                        last;
                    }
                }
            }
            push $_CALLBACK_CTX->{params}->@*, +{
                name        => '$_',
                type        => $elem_type,
                line        => $topic_line,
                col         => $topic_col,
                scope_start => $block_line,
                scope_end   => $block_end,
            };
        }
    }

    if ($name eq 'map') {
        return undef unless $elem_type;
        # Build env with $_ bound to element type
        my %new_vars = ($env->{variables} // +{})->%*;
        $new_vars{'$_'} = $elem_type;
        my $inner_env = +{ %$env, variables => \%new_vars };
        # Extract element expected type from Array[T]
        my $block_expected = ($expected && $expected->is_param && $expected->base eq 'Array')
            ? ($expected->params)[0] : undef;
        my $ret = _infer_block_return($block, $inner_env, $block_expected);
        # Widen literals to base atoms
        $ret = Typist::Type::Atom->new($ret->base_type)
            if $ret && $ret->is_literal;
        # List type: map returns a list, not a reference
        return Typist::Type::Param->new('Array', $ret // Typist::Type::Atom->new('Any'));
    }

    if ($name eq 'grep' || $name eq 'sort') {
        return $elem_type
            ? Typist::Type::Param->new('Array', $elem_type)
            : undef;
    }

    undef;
}

# Walk siblings after the block to find the source list, then infer its element type.
# Patterns: @$var, @array, $arrayref, func(...)
sub _infer_source_element_type_after ($block, $env) {
    my $sib = $block->snext_sibling;
    return undef unless $sib;

    # Skip leading comma if present
    if ($sib->isa('PPI::Token::Operator') && $sib->content eq ',') {
        $sib = $sib->snext_sibling;
        return undef unless $sib;
    }

    # @$ref — Cast('@') + Symbol
    if ($sib->isa('PPI::Token::Cast') && $sib->content eq '@') {
        my $sym = $sib->snext_sibling;
        if ($sym && $sym->isa('PPI::Token::Symbol')) {
            my $var_type = _lookup_var($sym->content, $env);
            return _unwrap_arrayref($var_type) if $var_type;
        }
        return undef;
    }

    # @array — Symbol with @ sigil
    if ($sib->isa('PPI::Token::Symbol') && $sib->raw_type eq '@') {
        my $scalar = $sib->content;
        $scalar =~ s/\A\@/\$/;
        my $var_type = _lookup_var($scalar, $env)
                    // _lookup_var($sib->content, $env);  # fallback: @name key
        return _unwrap_arrayref($var_type) if $var_type;
        return undef;
    }

    # $ref — scalar Symbol → ArrayRef unwrap
    if ($sib->isa('PPI::Token::Symbol') && $sib->raw_type eq '$') {
        my $var_type = _lookup_var($sib->content, $env);
        return _unwrap_arrayref($var_type) if $var_type;
        return undef;
    }

    # Chained map/grep/sort — e.g., grep { ... } @list as source for outer map
    if ($sib->isa('PPI::Token::Word')
        && ($sib->content eq 'map' || $sib->content eq 'grep' || $sib->content eq 'sort'))
    {
        my $after = $sib->snext_sibling;
        if ($after && $after->isa('PPI::Structure::Block')) {
            my $chain_result = _infer_map_grep_sort($sib, $env);
            if ($chain_result && $chain_result->is_param && $chain_result->base eq 'Array') {
                return ($chain_result->params)[0];
            }
            return undef;
        }
    }

    # func(...) — Word + List
    if ($sib->isa('PPI::Token::Word')) {
        my $after = $sib->snext_sibling;
        if ($after && $after->isa('PPI::Structure::List')) {
            my $ret = _infer_call($sib->content, $env, $after);
            return _unwrap_arrayref($ret) if $ret;
        }
        return undef;
    }

    undef;
}


# ── Anonymous Sub Inference ────────────────────────

# Infer the type of an anonymous sub expression: sub [($sig)] { body }
# Uses bidirectional inference: if $expected is a Func type, propagates
# parameter types and checks arity. Infers return type from block body.
sub _infer_anon_sub ($element, $env = undef, $expected = undef) {
    my $param_count = 0;
    my $sig_node;
    my $block;
    my $next = $element->snext_sibling;

    # Signature (PPI parses as Prototype for anonymous subs)
    if ($next && ($next->isa('PPI::Structure::List') || $next->isa('PPI::Token::Prototype'))) {
        $sig_node = $next;
        $param_count = _count_sub_params($next);
        $next = $next->snext_sibling;
    }

    # Block body
    $block = $next if $next && $next->isa('PPI::Structure::Block');

    # Bidirectional: if expected type is Func, propagate param types
    if ($expected && $expected->is_func) {
        my @expected_params = $expected->params;
        my @params;

        my $arity_match = ($param_count == scalar @expected_params)
            || ($expected->variadic && $param_count >= scalar(@expected_params) - 1);

        if ($arity_match) {
            @params = @expected_params;
        } else {
            @params = map { Typist::Type::Atom->new('Any') } 1 .. $param_count;
        }

        # Infer return type from block body with param types injected into env
        my $ret_type = $expected->returns;
        if ($block && $env) {
            my $body_env = ($sig_node && $arity_match)
                ? _enrich_env_with_params($env, $sig_node, \@params, $block)
                : $env;
            my $body_type = _infer_block_return($block, $body_env, $ret_type);
            $ret_type = $body_type if $body_type;
        }

        return Typist::Type::Func->new(
            \@params, $ret_type // Typist::Type::Atom->new('Any'),
        );
    }

    # No expected type — infer generic Func
    my @params = map { Typist::Type::Atom->new('Any') } 1 .. $param_count;
    my $ret_type = Typist::Type::Atom->new('Any');

    if ($block && $env) {
        my $body_type = _infer_block_return($block, $env);
        $ret_type = $body_type if $body_type;
    }

    Typist::Type::Func->new(\@params, $ret_type);
}

# Count parameters in a sub signature.
# PPI parses anonymous sub signatures as PPI::Token::Prototype (e.g., '($x, $y)'),
# while named sub signatures may use PPI::Structure::List.
sub _count_sub_params ($sig) {
    # Prototype token: parse string content for variable sigils
    if ($sig->isa('PPI::Token::Prototype')) {
        my $content = $sig->content;
        my $count = 0;
        $count++ while $content =~ /[\$\@%]\w/g;
        return $count;
    }

    # List structure: walk children for Symbol tokens
    my $expr = $sig->schild(0);
    return 0 unless $expr;

    my $count = 0;
    for my $tok ($expr->schildren) {
        $count++ if $tok->isa('PPI::Token::Symbol') && $tok->content =~ /\A[\$\@%]/;
    }
    $count;
}

# Extract parameter names from a sub signature node.
# Returns ['$x', '$y'] etc.  Mirrors _count_sub_params but returns names.
sub _extract_param_names ($sig) {
    if ($sig->isa('PPI::Token::Prototype')) {
        my $content = $sig->content;
        my @names;
        push @names, $1 while $content =~ /([\$\@%]\w+)/g;
        return \@names;
    }

    my $expr = $sig->schild(0);
    return [] unless $expr;

    my @names;
    for my $tok ($expr->schildren) {
        push @names, $tok->content
            if $tok->isa('PPI::Token::Symbol') && $tok->content =~ /\A[\$\@%]/;
    }
    \@names;
}

# Build a new env with parameter name → type bindings injected into {variables}.
# When $block is provided, records param info in the collector for LSP symbol index.
sub _enrich_env_with_params ($env, $sig_node, $expected_types, $block = undef) {
    return $env unless $env && $sig_node && $expected_types && @$expected_types;

    my $names = _extract_param_names($sig_node);
    return $env unless $names && @$names;

    my %new_vars = ($env->{variables} // +{})->%*;
    for my $i (0 .. $#$names) {
        last if $i > $#$expected_types;
        my $type = $expected_types->[$i];
        $new_vars{$names->[$i]} = $type;

        # Record for LSP hover/inlay hints (skip Any/unresolved params)
        if ($block && !($type->is_atom && $type->name eq 'Any')
                    && !$type->free_vars) {
            my $dedup_key = $names->[$i] . ':' . $sig_node->line_number;
            next if $_CALLBACK_CTX->{seen}{$dedup_key}++;
            push $_CALLBACK_CTX->{params}->@*, +{
                name        => $names->[$i],
                type        => $type,
                line        => $sig_node->line_number,
                col         => _param_col($sig_node, $names->[$i]),
                scope_start => $block->line_number,
                scope_end   => $block->last_token->line_number,
            };
        }
    }
    +{ %$env, variables => \%new_vars };
}

# Find column number of a specific parameter name within a signature node.
sub _param_col ($sig_node, $name) {
    if ($sig_node->isa('PPI::Token::Prototype')) {
        my $content = $sig_node->content;
        my $offset = index($content, $name);
        return $sig_node->column_number + ($offset >= 0 ? $offset : 0);
    }
    my $expr = $sig_node->schild(0);
    return $sig_node->column_number unless $expr;
    for my $tok ($expr->schildren) {
        return $tok->column_number
            if $tok->isa('PPI::Token::Symbol') && $tok->content eq $name;
    }
    $sig_node->column_number;
}

1;
