package Typist::Static::TypeEnv;
use v5.40;

# ── Anonymous Sub Parameter Injection ────────────
#
# Walk ancestors from $node up to $fn_block, detecting enclosing anonymous
# subs and injecting their parameter types into the env.  Handles three
# patterns:  match arms, HOF callbacks, and return closures.

sub _inject_anon_sub_params ($self, $env, $node, $fn_block, $fn) {
    my $cache_key = join "\0", Scalar::Util::refaddr($env),
        Scalar::Util::refaddr($node), Scalar::Util::refaddr($fn_block);
    if (exists $self->{_anon_param_env_cache}{$cache_key}) {
        return $self->{_anon_param_env_cache}{$cache_key};
    }

    my $ancestor = $node->parent;
    while ($ancestor && $ancestor != $fn_block) {
        if ($ancestor->isa('PPI::Structure::Block')) {
            my $prev = $ancestor->sprevious_sibling;
            my $sig_node;
            if ($prev && ($prev->isa('PPI::Token::Prototype')
                        || $prev->isa('PPI::Structure::List')))
            {
                $sig_node = $prev;
                $prev = $prev->sprevious_sibling;
            }
            if ($prev && $prev->isa('PPI::Token::Word') && $prev->content eq 'sub') {
                my @param_types = $self->_detect_anon_sub_param_types(
                    $prev, $env, $fn_block, $fn,
                );
                if (@param_types && $sig_node) {
                    $env = _enrich_env_from_sig($env, $sig_node, \@param_types);
                }
            }
        }
        $ancestor = $ancestor->parent;
    }
    return $self->{_anon_param_env_cache}{$cache_key} = $env;
}

# Determine parameter types for an anonymous sub from its calling context.
sub _detect_anon_sub_param_types ($self, $sub_word, $env, $fn_block, $fn) {
    my $before_sub = $sub_word->sprevious_sibling;

    # Pattern 1: Match arm — Tag => sub ($param) { ... }
    if ($before_sub && $before_sub->isa('PPI::Token::Operator')
        && $before_sub->content eq '=>')
    {
        my $tag = $before_sub->sprevious_sibling;
        if ($tag && $tag->isa('PPI::Token::Word')) {
            my @types = $self->_match_arm_param_types($tag->content, $tag, $env);
            return @types if @types;
        }
    }

    # Pattern 2: HOF callback — func(args..., sub ($param) { ... })
    my @hof = $self->_hof_callback_param_types($sub_word, $env);
    return @hof if @hof;

    # Pattern 3: Return closure — function returns Func type
    return $self->_return_closure_param_types($sub_word, $fn_block, $fn);
}

# ── Pattern 1: Match arm ────────────────────────
# Walk backward from the tag word to find `match EXPR`, infer its type,
# and return the variant's inner types for the given constructor tag.

sub _match_arm_param_types ($self, $tag, $tag_word, $env) {
    my $sib = $tag_word;
    while ($sib = $sib->sprevious_sibling) {
        if ($sib->isa('PPI::Token::Word') && $sib->content eq 'match') {
            my $val_node = $sib->snext_sibling or return ();
            my $val_type = Typist::Static::Infer->infer_expr($val_node, $env);
            return () unless $val_type;
            return $self->_variant_types_for($val_type, $tag);
        }
    }
    ();
}

# Resolve a type to its Data definition and return the variant's inner types.
sub _variant_types_for ($self, $type, $tag) {
    my $registry = $self->{registry} // return ();

    my ($type_name, @args);
    if ($type->is_atom) {
        $type_name = $type->name;
    } elsif ($type->is_param) {
        $type_name = $type->base;
        $type_name = "$type_name" if ref $type_name;
        @args = $type->params;
    } elsif ($type->is_alias) {
        my $resolved = eval { $registry->lookup_type($type->alias_name) };
        return $self->_variant_types_for($resolved, $tag) if $resolved;
        return ();
    } else {
        return ();
    }

    $type_name = "$type_name" if ref $type_name;
    my $dt = $registry->lookup_datatype($type_name) // return ();

    my %bindings;
    my @params = $dt->type_params;
    for my $i (0 .. $#params) {
        $bindings{$params[$i]} = $args[$i] if $i <= $#args && $args[$i];
    }

    my $variants = $dt->variants // return ();
    return () unless $variants->{$tag};
    my @types = @{$variants->{$tag}};
    if (%bindings) {
        @types = map { $_->substitute(\%bindings) } @types;
    }
    @types;
}

# ── Pattern 2: HOF callback ─────────────────────
# Detect func(args..., sub ($param) { ... }) and bind generic type vars
# from concrete args to determine callback parameter types.

sub _hof_callback_param_types ($self, $sub_word, $env) {
    my $parent = $sub_word->parent or return ();

    # The sub should be inside a Statement within a List (function args)
    my $container = $parent;
    $container = $container->parent
        if $container->isa('PPI::Statement') || $container->isa('PPI::Statement::Expression');
    return () unless $container && $container->isa('PPI::Structure::List');

    my $func_word = $container->sprevious_sibling;
    return () unless $func_word && $func_word->isa('PPI::Token::Word');

    my $func_name = $func_word->content;
    (my $short_name = $func_name) =~ s/.*:://;
    my $registry = $self->{registry} // return ();

    my $sig = $registry->search_function_by_name($short_name);
    return () unless $sig && $sig->{params} && $sig->{generics} && @{$sig->{generics}};

    # Determine callback position and collect other args
    my $expr = $container->schild(0);
    $expr = undef unless $expr && $expr->isa('PPI::Statement');
    return () unless $expr;

    my @children = $expr->schildren;
    my (@args, $cb_pos);
    my $arg_idx = 0;
    my $ci = 0;
    while ($ci <= $#children) {
        my $child = $children[$ci];
        if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
            $ci++;
            next;
        }
        if ($child == $sub_word) {
            $cb_pos = $arg_idx;
            $ci++;
            # Skip rest of anon sub tokens
            while ($ci <= $#children && ($children[$ci]->isa('PPI::Token::Prototype')
                || $children[$ci]->isa('PPI::Structure::List')
                || $children[$ci]->isa('PPI::Structure::Block')))
            {
                $ci++;
            }
            $arg_idx++;
            next;
        }
        # Anonymous sub coalescing
        if ($child->isa('PPI::Token::Word') && $child->content eq 'sub') {
            push @args, +{ node => $child };
            $ci++;
            while ($ci <= $#children && ($children[$ci]->isa('PPI::Token::Prototype')
                || $children[$ci]->isa('PPI::Structure::List')
                || $children[$ci]->isa('PPI::Structure::Block')))
            {
                $ci++;
            }
            $arg_idx++;
            next;
        }
        # Function call coalescing
        if ($child->isa('PPI::Token::Word') && $ci + 1 <= $#children
            && $children[$ci + 1]->isa('PPI::Structure::List'))
        {
            push @args, +{ node => $child };
            $ci += 2;
            $arg_idx++;
            next;
        }
        push @args, +{ node => $child };
        $ci++;
        $arg_idx++;
    }
    return () unless defined $cb_pos;

    my @sig_params = @{$sig->{params}};
    return () unless $cb_pos <= $#sig_params;

    my $cb_type = $sig_params[$cb_pos];
    return () unless $cb_type && $cb_type->is_func;

    # Bind free vars from concrete args
    my %bindings;
    for my $i (0 .. $#args) {
        last if $i > $#sig_params;
        my $pos = $i >= $cb_pos ? $i + 1 : $i;   # adjust for callback position
        next if $pos > $#sig_params;
        my $arg_type = Typist::Static::Infer->infer_expr($args[$i]{node}, $env);
        next unless $arg_type;
        _bind_type_vars($sig_params[$pos], $arg_type, \%bindings);
    }

    my @cb_params = $cb_type->params;
    if (%bindings) {
        @cb_params = map { $_->substitute(\%bindings) } @cb_params;
    }
    # Filter out unresolved type variables
    grep { !$_->is_var } @cb_params;
}

# ── Pattern 3: Return closure ────────────────────
# If the anonymous sub is the return value of a function with Func return type,
# use the Func's param types.

sub _return_closure_param_types ($self, $sub_word, $fn_block, $fn) {
    return () unless $fn && $fn->{returns_expr};

    my $ret_type = $self->resolve_type($fn->{returns_expr});
    return () unless $ret_type && $ret_type->is_func;

    # Check that the sub is at the statement level of the function body
    # (implicit return or explicit `return sub { ... }`)
    my $stmt = $sub_word->parent;
    return () unless $stmt;
    return () unless $stmt->parent == $fn_block
                  || ($stmt->parent && $stmt->parent->parent
                      && $stmt->parent->parent == $fn_block);

    $ret_type->params;
}

# ── Shared helpers ───────────────────────────────

# Extract param names from a Prototype or List node and inject types into env.
sub _enrich_env_from_sig ($env, $sig_node, $param_types) {
    my @names;
    if ($sig_node->isa('PPI::Token::Prototype')) {
        my $content = $sig_node->content;
        $content =~ s/\A\(//;
        $content =~ s/\)\z//;
        @names = map  { s/\s*=.*//r }
                 grep { /\A[\$\@%]/ }
                 split /\s*,\s*/, $content;
    } elsif ($sig_node->isa('PPI::Structure::List')) {
        my $expr = $sig_node->find_first('PPI::Statement::Expression')
                || $sig_node->find_first('PPI::Statement');
        if ($expr) {
            @names = map  { $_->content }
                     grep { $_->isa('PPI::Token::Symbol') } $expr->schildren;
        }
    }
    return $env unless @names && @$param_types;

    my %new_vars = ($env->{variables} // +{})->%*;
    for my $i (0 .. $#names) {
        last if $i > $#$param_types;
        $new_vars{$names[$i]} = $param_types->[$i];
    }
    +{ %$env, variables => \%new_vars };
}

# Recursively bind type variables by matching a signature type against an actual type.
sub _bind_type_vars ($sig_type, $actual_type, $bindings) {
    if ($sig_type->is_var) {
        $bindings->{$sig_type->name} //= $actual_type;
    } elsif ($sig_type->is_param && $actual_type->is_param
             && $sig_type->base eq $actual_type->base)
    {
        my @sp = $sig_type->params;
        my @ap = $actual_type->params;
        for my $i (0 .. $#sp) {
            _bind_type_vars($sp[$i], $ap[$i], $bindings) if $i <= $#ap;
        }
    }
}

1;
