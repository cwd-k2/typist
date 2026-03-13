package Typist::Static::Infer;
use v5.40;

# ── Operator Expression Inference ───────────────
#
# Handles binary operators, ternary expressions (simple and nested),
# mixed-precedence splitting, and defined() narrowing for ternary branches.

my %OP_PRECEDENCE = (
    'or' => 1, 'xor' => 1,  'and' => 2,
    '||' => 3, '//'  => 3,  '&&'  => 4,
    '=~' => 5, '!~'  => 5,
    '==' => 6, '!='  => 6, '<=>' => 6,
    '<'  => 6, '>'   => 6, '<='  => 6, '>=' => 6,
    'eq' => 6, 'ne'  => 6, 'cmp' => 6,
    'lt' => 6, 'gt'  => 6, 'le'  => 6, 'ge' => 6,
    '+'  => 7, '-'   => 7, '.'   => 7,
    '*'  => 8, '/'   => 8, '%'   => 8, 'x'  => 8,
    '**' => 9,
);
my %NUMERIC_ATOM = map { $_ => 1 } qw(Bool Int Double Num);

sub _infer_operator_expr ($stmt, $env, $expected = undef) {
    my @children = grep { !$_->isa('PPI::Token::Structure') } $stmt->schildren;

    return undef unless @children >= 2;

    # Ternary pre-check: if any child is `?`, this is a ternary expression.
    # Must be checked before subscript/method chain patterns which would
    # greedily match the condition part (e.g., $p->stock > 0 ? ... : ...).
    if (@children >= 5
        && grep { $_->isa('PPI::Token::Operator') && $_->content eq '?' } @children)
    {
        # Simple ternary: exactly 5 children
        if (@children == 5
            && $children[1]->isa('PPI::Token::Operator') && $children[1]->content eq '?'
            && $children[3]->isa('PPI::Token::Operator') && $children[3]->content eq ':')
        {
            return _infer_ternary($children[2], $children[4], $env, $expected);
        }
        my $result = _infer_flat_ternary(\@children, $env, $expected);
        return $result if defined $result;
    }

    # Unary: ! Expr  or  not Expr
    if (@children == 2
        && $children[0]->isa('PPI::Token::Operator')
        && ($children[0]->content eq '!' || $children[0]->content eq 'not'))
    {
        return Typist::Type::Atom->new('Bool');
    }

    # Subscript/method chain and CodeRef: $sym->{key}, $sym->method, $f->(args)
    # Also handles chain + operator: $a->x - $b->y, $a->stock >= 0
    if (@children >= 3
        && $children[0]->isa('PPI::Token::Symbol')
        && $children[1]->isa('PPI::Token::Operator') && $children[1]->content eq '->'
        && ($children[2]->isa('PPI::Structure::Subscript') || $children[2]->isa('PPI::Token::Word')
            || $children[2]->isa('PPI::Structure::List')))
    {
        if ($env) {
            my $var_type = $env->{variables}{$children[0]->content};
            if ($var_type) {
                my $chain_type = _chase_subscript_chain($var_type, $children[0], $env);
                # Find chain end in children array
                my $ci = 2;
                unless ($children[$ci]->isa('PPI::Structure::List')) {
                    $ci++ if $ci < $#children && $children[$ci + 1]->isa('PPI::Structure::List');
                    while ($ci + 2 <= $#children
                           && $children[$ci + 1]->isa('PPI::Token::Operator') && $children[$ci + 1]->content eq '->'
                           && ($children[$ci + 2]->isa('PPI::Structure::Subscript') || $children[$ci + 2]->isa('PPI::Token::Word')))
                    {
                        $ci += 2;
                        $ci++ if $ci < $#children && $children[$ci + 1]->isa('PPI::Structure::List');
                    }
                }
                # Pure accessor chain (no trailing operator)
                return $chain_type if $ci >= $#children;
                # Chain followed by operator — combine with rest
                if (defined $chain_type && $children[$ci + 1]->isa('PPI::Token::Operator')) {
                    my $op = $children[$ci + 1]->content;
                    my @rest = @children[$ci + 2 .. $#children];
                    my $rt = @rest == 1 ? __PACKAGE__->infer_expr($rest[0], $env)
                                        : _infer_children_slice(\@rest, $env);
                    return _result_type_for_op($op, $chain_type, $rt, $env);
                }
            }
        }
        return undef;
    }

    # Function call chain: func()->{key}, func()->method, func()->[0]->{name}
    if (@children >= 4
        && $children[0]->isa('PPI::Token::Word')
        && $children[1]->isa('PPI::Structure::List')
        && $children[2]->isa('PPI::Token::Operator') && $children[2]->content eq '->'
        && ($children[3]->isa('PPI::Structure::Subscript') || $children[3]->isa('PPI::Token::Word')))
    {
        my $call_type = _infer_call($children[0]->content, $env, $children[1]);
        return _chase_subscript_chain($call_type, $children[1], $env) if defined $call_type;
        return undef;
    }

    # Function call + operator: func(args) OP rhs (e.g., length($s) > 0)
    if (@children >= 4
        && $children[0]->isa('PPI::Token::Word')
        && $children[1]->isa('PPI::Structure::List')
        && $children[2]->isa('PPI::Token::Operator'))
    {
        my $op = $children[2]->content;
        if ($op ne '=' && $op ne '->' && $op ne '=>') {
            return _infer_binop($op, $children[0], $children[3], $env) if @children == 4;
            # 5+ children: might be func(args) OP rhs OP2 ... — use children_slice
            my @right = @children[2 .. $#children];
            my $lt = _infer_call($children[0]->content, $env, $children[1]);
            if (defined $lt) {
                my $rt = _infer_children_slice([@children[3 .. $#children]], $env);
                return _result_type_for_op($op, $lt, $rt, $env);
            }
        }
    }

    # Binary: Expr Op Expr  (exactly 3 significant children)
    if (@children == 3 && $children[1]->isa('PPI::Token::Operator')) {
        return _infer_binop($children[1]->content, $children[0], $children[2], $env);
    }

    # Chained/mixed binary: Expr Op Expr Op Expr ... (5+ children)
    # Handles both same-operator chains and mixed operators (e.g., >= && <=)
    if (@children >= 5) {
        my $result = _infer_children_slice(\@children, $env);
        return $result if defined $result;
    }

    undef;
}

# Infer a ternary branch slice (tokens between ? and : or after :).
# Handles: single token, function call (Word + List), nested ternary.
sub _infer_branch_slice ($slice, $env, $expected) {
    return undef unless $slice && @$slice;
    if (@$slice == 1) {
        return __PACKAGE__->infer_expr($slice->[0], $env, $expected);
    }
    # Check for nested ternary (has ? operator)
    my $has_ternary = grep { $_->isa('PPI::Token::Operator') && $_->content eq '?' } @$slice;
    if ($has_ternary) {
        return _infer_flat_ternary($slice, $env, $expected);
    }
    # Multi-token: infer from first element (PPI sibling chain handles Word+List etc.)
    return __PACKAGE__->infer_expr($slice->[0], $env, $expected);
}

# ── Mixed-Operator Helpers ──────────────────────
# Split a flat expression at the lowest-precedence operator and recurse.

# Find the index of the lowest-precedence operator in @children.
sub _find_split_point ($children) {
    my ($best_idx, $best_prec);
    for my $i (0 .. $#$children) {
        next unless $children->[$i]->isa('PPI::Token::Operator');
        my $op = $children->[$i]->content;
        my $prec = $OP_PRECEDENCE{$op} // next;
        if (!defined $best_prec || $prec <= $best_prec) {
            $best_prec = $prec;
            $best_idx  = $i;
        }
    }
    $best_idx;
}

# Determine result type from operator category and operand types.
# Operand types may be undef (unknown); result is determined by operator category.
sub _result_type_for_op ($op, $lt, $rt, $env = undef) {
    # Comparison → Bool (regardless of operand types)
    return Typist::Type::Atom->new('Bool')
        if $op =~ /\A(?:==|!=|<|>|<=|>=|<=>|eq|ne|lt|gt|le|ge|cmp|=~|!~)\z/;
    # Defined-or → strip Undef from LHS, LUB with RHS
    if ($op eq '//') {
        my $stripped = $lt;
        if ($lt && $lt->is_union) {
            my @non_undef = grep { !($_->is_atom && $_->name eq 'Undef') } $lt->members;
            if (@non_undef < scalar($lt->members)) {
                $stripped = @non_undef == 1 ? $non_undef[0] : Typist::Type::Union->new(@non_undef);
            }
        }
        return $stripped if $stripped && !$rt;
        return $rt if $rt && !$stripped;
        return Typist::Subtype->common_super($stripped, $rt) if $stripped && $rt;
        return undef;
    }
    # Logical → left operand type (undef if left is unknown)
    return $lt if $op =~ /\A(?:&&|\|\||and|or|xor)\z/;
    # Arithmetic → LUB of numeric atoms, fallback Num
    if ($op =~ /\A(?:\+|-|\*|\/|%|\*\*)\z/) {
        my $lw = $lt && $lt->is_literal ? Typist::Type::Atom->new($lt->base_type) : $lt;
        my $rw = $rt && $rt->is_literal ? Typist::Type::Atom->new($rt->base_type) : $rt;
        # Resolve type aliases and alias objects (e.g., Alias(Quantity) → Atom(Int))
        my $registry = $env && $env->{registry};
        if ($registry) {
            for my $ref (\$lw, \$rw) {
                next unless $$ref;
                my $name = $$ref->name // next;
                next if $NUMERIC_ATOM{$name};
                if ($$ref->is_atom || $$ref->is_alias) {
                    my $res = eval { $registry->lookup_type($name) };
                    $$ref = $res if $res && $res->is_atom;
                }
            }
        }
        if ($lw && $rw && $lw->is_atom && $rw->is_atom
            && $NUMERIC_ATOM{$lw->name} && $NUMERIC_ATOM{$rw->name})
        {
            return Typist::Subtype->common_super($lw, $rw);
        }
        return Typist::Type::Atom->new('Num');
    }
    # String → Str
    return Typist::Type::Atom->new('Str') if $op eq '.' || $op eq 'x';
    undef;
}

# Recursively infer a flat children slice by splitting at lowest-precedence op.
sub _infer_children_slice ($children, $env) {
    return undef unless $children && @$children;
    # Single element → infer directly
    return __PACKAGE__->infer_expr($children->[0], $env) if @$children == 1;
    # 3 elements (simple binary) → _infer_binop
    if (@$children == 3 && $children->[1]->isa('PPI::Token::Operator')) {
        # Accessor chain: $sym->method — delegate to infer_expr (PPI sibling chase)
        if ($children->[1]->content eq '->'
            && $children->[0]->isa('PPI::Token::Symbol'))
        {
            return __PACKAGE__->infer_expr($children->[0], $env);
        }
        return _infer_binop($children->[1]->content, $children->[0], $children->[2], $env);
    }
    # 5+ elements → split at lowest-precedence operator
    my $split = _find_split_point($children);
    unless (defined $split && $split > 0 && $split < $#$children) {
        # No split point — accessor chain leaf (only -> operators remain)
        return __PACKAGE__->infer_expr($children->[0], $env)
            if $children->[0]->isa('PPI::Token::Symbol');
        return undef;
    }
    my @left  = @$children[0 .. $split - 1];
    my @right = @$children[$split + 1 .. $#$children];
    my $lt = _infer_children_slice(\@left,  $env);
    my $rt = _infer_children_slice(\@right, $env);
    _result_type_for_op($children->[$split]->content, $lt, $rt, $env);
}

# Check for ternary extension after a function call or subscript chain.
# Walks past any -> chains from $after_node, then checks for ? then : else.
# Returns the ternary type if found, otherwise returns $result unchanged.
sub _check_ternary_extension ($result, $after_node, $env, $expected) {
    # Walk past -> chains to find what comes after
    my $node = $after_node->snext_sibling;
    while ($node && $node->isa('PPI::Token::Operator') && $node->content eq '->') {
        my $next = $node->snext_sibling or last;
        # Skip -> Subscript, -> Word, -> List
        if ($next->isa('PPI::Structure::List')) {
            $node = $next->snext_sibling;
            next;
        }
        $node = $next->snext_sibling;
    }
    # Check for ? then : else
    if ($node && $node->isa('PPI::Token::Operator') && $node->content eq '?') {
        my $then_expr = $node->snext_sibling;
        my $colon = $then_expr ? $then_expr->snext_sibling : undef;
        if ($colon && $colon->isa('PPI::Token::Operator') && $colon->content eq ':') {
            my $else_expr = $colon->snext_sibling;
            if ($else_expr) {
                # Narrow env for then-branch when condition is defined(...)
                my $then_env = $env;
                my $cond_word = $after_node->sprevious_sibling;
                if ($cond_word && $cond_word->isa('PPI::Token::Word')
                    && $cond_word->content eq 'defined'
                    && $after_node->isa('PPI::Structure::List') && $env)
                {
                    $then_env = _narrow_for_defined_condition($after_node, $env);
                }
                my $then_type = __PACKAGE__->infer_expr($then_expr, $then_env, $expected);
                my $else_type = __PACKAGE__->infer_expr($else_expr, $env, $expected);
                return undef unless defined $then_type && defined $else_type;
                return _infer_ternary_types($then_type, $else_type, $env, $expected);
            }
        }
    }
    $result;
}

# Narrow env for the then-branch of a defined() ternary condition.
# Handles both simple variables (defined($s)) and accessor chains (defined($w->tip)).
sub _narrow_for_defined_condition ($cond_list, $env) {
    return $env unless $env;

    my $inner = $cond_list->find_first('PPI::Token::Symbol');
    return $env unless $inner && $inner->raw_type eq '$';

    my $var_name = $inner->content;
    my $var_type = $env->{variables}{$var_name};

    # Simple variable: defined($var) where $var is Union containing Undef
    if ($var_type && $var_type->is_union) {
        my @non_undef = grep { !($_->is_atom && $_->name eq 'Undef') } $var_type->members;
        if (@non_undef < scalar($var_type->members)) {
            my $narrowed = @non_undef == 1 ? $non_undef[0]
                : Typist::Type::Union->new(@non_undef);
            my %new_vars = $env->{variables}->%*;
            $new_vars{$var_name} = $narrowed;
            return +{ %$env, variables => \%new_vars };
        }
    }

    # Accessor chain: defined($var->field) or defined($var->a->b) — infer and narrow
    my $next_sib = $inner->snext_sibling;
    if ($next_sib && $next_sib->isa('PPI::Token::Operator') && $next_sib->content eq '->') {
        # Extract full accessor chain: walk ->word[()] pairs
        my @chain;
        my $cursor = $next_sib;
        while ($cursor && $cursor->isa('PPI::Token::Operator') && $cursor->content eq '->') {
            my $word = $cursor->snext_sibling;
            last unless $word && $word->isa('PPI::Token::Word');
            push @chain, $word->content;
            my $after = $word->snext_sibling;
            # Skip method call parens
            $after = $after->snext_sibling
                if $after && $after->isa('PPI::Structure::List');
            $cursor = $after;
        }
        if (@chain) {
            # Infer full accessor type (chases chain via siblings)
            my $acc_type = __PACKAGE__->infer_expr($inner, $env);
            if ($acc_type && $acc_type->is_union) {
                my @non_undef = grep { !($_->is_atom && $_->name eq 'Undef') } $acc_type->members;
                if (@non_undef < scalar($acc_type->members)) {
                    my $narrowed = @non_undef == 1 ? $non_undef[0]
                        : Typist::Type::Union->new(@non_undef);
                    my %acc = ($env->{narrowed_accessors} // +{})->%*;
                    my $c = \%acc;
                    $c = ($c->{$var_name} //= +{});
                    for my $i (0 .. $#chain) {
                        if ($i == $#chain) {
                            $c->{$chain[$i]}{__type__} = $narrowed;
                        } else {
                            $c = ($c->{$chain[$i]} //= +{});
                        }
                    }
                    return +{ %$env, narrowed_accessors => \%acc };
                }
            }
        }
    }

    $env;
}

# Handle nested ternary from a flat PPI children list.
# PPI flattens `Cond ? Then : Cond2 ? Then2 : Else` into a single list.
# Finds the first ? and its matching :, then recurses for nested else branches.
sub _infer_flat_ternary ($children, $env, $expected) {
    # Find first ? operator
    my $q_idx;
    for my $i (0 .. $#$children) {
        if ($children->[$i]->isa('PPI::Token::Operator') && $children->[$i]->content eq '?') {
            $q_idx = $i;
            last;
        }
    }
    return undef unless defined $q_idx;

    # Find matching : (depth-counted for nested ternary)
    my ($depth, $c_idx) = (0, undef);
    for my $i ($q_idx + 1 .. $#$children) {
        if ($children->[$i]->isa('PPI::Token::Operator')) {
            if    ($children->[$i]->content eq '?') { $depth++ }
            elsif ($children->[$i]->content eq ':') {
                if ($depth == 0) { $c_idx = $i; last }
                $depth--;
            }
        }
    }
    return undef unless defined $c_idx;

    # Narrow env for then-branch when condition is defined(...)
    my $then_env = $env;
    my @cond_slice = @$children[0 .. $q_idx - 1];
    if (@cond_slice == 2
        && $cond_slice[0]->isa('PPI::Token::Word') && $cond_slice[0]->content eq 'defined'
        && $cond_slice[1]->isa('PPI::Structure::List') && $env)
    {
        $then_env = _narrow_for_defined_condition($cond_slice[1], $env);
    }

    # Then: tokens between ? and :
    my @then_slice = @$children[$q_idx + 1 .. $c_idx - 1];
    return undef unless @then_slice;
    my $then_type = _infer_branch_slice(\@then_slice, $then_env, $expected);

    # Else: everything after :
    my @else_slice = @$children[$c_idx + 1 .. $#$children];
    my $else_type = _infer_branch_slice(\@else_slice, $env, $expected);

    return undef unless defined $then_type && defined $else_type;
    _infer_ternary_types($then_type, $else_type, $env, $expected);
}

sub _infer_ternary ($then_expr, $else_expr, $env, $expected = undef) {
    my $then_type = __PACKAGE__->infer_expr($then_expr, $env, $expected);
    my $else_type = __PACKAGE__->infer_expr($else_expr, $env, $expected);
    return undef unless defined $then_type && defined $else_type;
    _infer_ternary_types($then_type, $else_type, $env, $expected);
}

# Combine two branch types from a ternary expression.
# Shared logic for both simple and nested ternary.
sub _infer_ternary_types ($then_type, $else_type, $env, $expected = undef) {
    # If expected type is available, check if both branches conform (before widening)
    if ($expected) {
        my $registry = $env ? $env->{registry} : undef;
        my @sub_args = $registry ? (registry => $registry) : ();
        if (Typist::Subtype->is_subtype($then_type, $expected, @sub_args)
            && Typist::Subtype->is_subtype($else_type, $expected, @sub_args)) {
            return $expected;
        }
    }

    # Widen literals to base atoms for result typing
    my $then_w = $then_type->is_literal ? Typist::Type::Atom->new($then_type->base_type) : $then_type;
    my $else_w = $else_type->is_literal ? Typist::Type::Atom->new($else_type->base_type) : $else_type;

    # Same type → unify
    return $then_w if $then_w->equals($else_w);

    # Try LUB via common_super; use Union when LUB is too coarse
    my $lub = Typist::Subtype->common_super($then_w, $else_w);
    return $lub if !($lub->is_atom && $lub->name eq 'Any');

    Typist::Type::Union->new($then_w, $else_w);
}

# Infer arithmetic result type from operand types.
# If both sides are numeric atoms, LUB preserves precision (Int+Int→Int).
# Falls back to Num when either side is unknown.
sub _infer_arithmetic ($lhs, $rhs, $env) {
    my $lt = __PACKAGE__->infer_expr($lhs, $env);
    my $rt = __PACKAGE__->infer_expr($rhs, $env);
    # Widen literals to base atom
    $lt = Typist::Type::Atom->new($lt->base_type) if $lt && $lt->is_literal;
    $rt = Typist::Type::Atom->new($rt->base_type) if $rt && $rt->is_literal;
    # Resolve type aliases and alias objects (e.g., Alias(Quantity) → Atom(Int))
    my $registry = $env && $env->{registry};
    if ($registry) {
        for my $ref (\$lt, \$rt) {
            next unless $$ref;
            my $name = $$ref->name // next;
            next if $NUMERIC_ATOM{$name};
            if ($$ref->is_atom || $$ref->is_alias) {
                my $res = eval { $registry->lookup_type($name) };
                $$ref = $res if $res && $res->is_atom;
            }
        }
    }
    if ($lt && $rt && $lt->is_atom && $rt->is_atom
        && $NUMERIC_ATOM{$lt->name} && $NUMERIC_ATOM{$rt->name})
    {
        return Typist::Subtype->common_super($lt, $rt);
    }
    Typist::Type::Atom->new('Num');
}

sub _infer_binop ($op, $lhs, $rhs, $env) {
    # Arithmetic → LUB of operand types (Int+Int→Int, Int+Double→Double, etc.)
    return _infer_arithmetic($lhs, $rhs, $env)
        if $op =~ /\A(?:\+|-|\*|\/|%|\*\*)\z/;

    # String concatenation / repetition → Str
    return Typist::Type::Atom->new('Str') if $op eq '.' || $op eq '.=' || $op eq 'x';

    # Compound assignment: +=, -=, *=, /= → LUB
    return _infer_arithmetic($lhs, $rhs, $env)
        if $op =~ /\A(?:\+=|-=|\*=|\/=|%=|\*\*=)\z/;

    # Numeric comparison → Bool
    return Typist::Type::Atom->new('Bool')
        if $op =~ /\A(?:==|!=|<|>|<=|>=|<=>)\z/;

    # String comparison → Bool
    return Typist::Type::Atom->new('Bool')
        if $op =~ /\A(?:eq|ne|lt|gt|le|ge|cmp)\z/;

    # Regex match → Bool
    return Typist::Type::Atom->new('Bool')
        if $op eq '=~' || $op eq '!~';

    # Defined-or → strip Undef from LHS, LUB with RHS
    # ($port // default_port()) where $port: Maybe[Int] → Int
    if ($op eq '//') {
        my $lt = __PACKAGE__->infer_expr($lhs, $env);
        my $rt = __PACKAGE__->infer_expr($rhs, $env);
        # // evaluates to LHS when defined: strip Undef from Union
        if ($lt && $lt->is_union) {
            my @non_undef = grep { !($_->is_atom && $_->name eq 'Undef') } $lt->members;
            if (@non_undef < scalar($lt->members)) {
                $lt = @non_undef == 1 ? $non_undef[0] : Typist::Type::Union->new(@non_undef);
            }
        }
        return $lt if $lt && !$rt;
        return $rt if $rt && !$lt;
        return Typist::Subtype->common_super($lt, $rt) if $lt && $rt;
        return undef;
    }

    # Logical → left operand type
    if ($op =~ /\A(?:&&|\|\||and|or)\z/) {
        return __PACKAGE__->infer_expr($lhs, $env);
    }

    undef;
}

1;
