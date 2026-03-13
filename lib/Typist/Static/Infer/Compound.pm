package Typist::Static::Infer;
use v5.40;

# ── Structural Constructors: Array / Hash ────────
#
# Infer types for [...] and {...} literal constructors, including tuple
# positioning, record inference, and bidirectional expected-type propagation.

sub _infer_array ($constructor, $env = undef, $expected = undef) {
    # Resolve alias on expected type (e.g., IntList → Union(Int, ArrayRef[IntList]))
    if ($expected && $expected->is_alias && $env && $env->{registry}) {
        my $resolved = $env->{registry}->lookup_type($expected->alias_name);
        $expected = $resolved if $resolved;
    }

    # PPI uses PPI::Statement (not ::Expression) inside array constructors
    my $expr = $constructor->find_first('PPI::Statement');

    # Empty array: use expected type if available
    unless ($expr) {
        return $expected if $expected && $expected->is_param
            && ($expected->base eq 'ArrayRef' || $expected->base eq 'Tuple');
        return Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Any'));
    }

    # Tuple expected: position-based inference
    if ($expected && $expected->is_param && $expected->base eq 'Tuple') {
        my @tuple_expected = $expected->params;
        # Collect non-operator children as elements
        my @children = $expr->schildren;
        my @elems;
        my $has_spread = 0;
        my $ci = 0;
        while ($ci <= $#children) {
            my $child = $children[$ci];
            if ($child->isa('PPI::Token::Operator')) { $ci++; next }
            # Spread or map/grep/sort → not a fixed-length tuple
            if ($child->isa('PPI::Token::Cast') && $child->content eq '@') {
                $has_spread = 1; last;
            }
            if ($child->isa('PPI::Token::Word')
                && ($child->content eq 'map' || $child->content eq 'grep' || $child->content eq 'sort'))
            {
                $has_spread = 1; last;
            }
            # Anonymous sub coalescing: sub + Prototype/List + Block → single element
            if ($child->isa('PPI::Token::Word') && $child->content eq 'sub') {
                push @elems, $child;
                $ci++;
                while ($ci <= $#children) {
                    last unless $children[$ci]->isa('PPI::Token::Prototype')
                             || $children[$ci]->isa('PPI::Structure::List')
                             || $children[$ci]->isa('PPI::Structure::Block');
                    $ci++;
                }
                next;
            }
            # Function call coalescing: Word + List → single element
            if ($child->isa('PPI::Token::Word') && $ci + 1 <= $#children
                && $children[$ci + 1]->isa('PPI::Structure::List'))
            {
                push @elems, $child;
                $ci += 2;
                next;
            }
            push @elems, $child;
            $ci++;
        }
        # Arity match and no spread → position-based inference
        if (!$has_spread && @elems == @tuple_expected) {
            my @inferred;
            for my $idx (0 .. $#elems) {
                my $t = __PACKAGE__->infer_expr($elems[$idx], $env, $tuple_expected[$idx]);
                push @inferred, $t // $tuple_expected[$idx];
            }
            return Typist::Type::Param->new('Tuple', @inferred);
        }
        # Fallback: arity mismatch or spread → treat as ArrayRef
    }

    # Extract element expected type from ArrayRef[T] or Union containing ArrayRef[T]
    my $elem_expected;
    if ($expected && $expected->is_param && $expected->base eq 'ArrayRef') {
        $elem_expected = ($expected->params)[0];
    } elsif ($expected && $expected->is_union) {
        for my $member ($expected->members) {
            if ($member->is_param && $member->base eq 'ArrayRef') {
                $elem_expected = ($member->params)[0];
                last;
            }
        }
    }

    # Single-expression array (no commas): infer the whole Statement as one element.
    # Handles complex expressions like [$p->method >= 5000 ? "a" : "b"]
    # where child-by-child iteration would only see the first token.
    my @children = $expr->schildren;
    my $has_comma = grep { $_->isa('PPI::Token::Operator') && $_->content eq ',' } @children;
    if (!$has_comma && @children > 1) {
        my $t = __PACKAGE__->infer_expr($expr, $env, $elem_expected);
        if (defined $t) {
            $t = ($t->params)[0] if $t->is_param && $t->base eq 'Array';
            $t = Typist::Type::Atom->new($t->base_type) if $t->is_literal;
            return Typist::Type::Param->new('ArrayRef', $t);
        }
    }

    my @elem_types;
    my $i = 0;
    while ($i <= $#children) {
        my $child = $children[$i];
        if ($child->isa('PPI::Token::Operator')) { $i++; next }  # skip commas, +

        # Detect map/grep/sort { BLOCK } LIST — consume the entire pattern
        if ($child->isa('PPI::Token::Word')
            && ($child->content eq 'map' || $child->content eq 'grep' || $child->content eq 'sort'))
        {
            my $t = __PACKAGE__->infer_expr($child, $env, $elem_expected);
            if (defined $t && $t->is_param && $t->base eq 'Array') {
                push @elem_types, ($t->params)[0];
                # Skip siblings consumed by map/grep/sort (block + source list)
                $i++;
                while ($i <= $#children) {
                    last if $children[$i]->isa('PPI::Token::Operator')
                         && $children[$i]->content eq ',';
                    $i++;
                }
                next;
            }
        }

        # @{$expr} or @$var — array dereference spread inside array constructor
        if ($child->isa('PPI::Token::Cast') && $child->content eq '@') {
            my $next_child = $children[$i + 1] // undef;
            # @{BLOCK} form
            if ($next_child && $next_child->isa('PPI::Structure::Block')) {
                my $inner = $next_child->find_first('PPI::Statement');
                if ($inner) {
                    my $first = $inner->schild(0);
                    if ($first) {
                        my $ref_type = __PACKAGE__->infer_expr($first, $env);
                        if ($ref_type) {
                            my $elem = _unwrap_arrayref($ref_type);
                            push @elem_types, $elem if $elem;
                        }
                    }
                }
                $i += 2;  # skip both Cast and Block
                next;
            }
            # @$var form
            if ($next_child && $next_child->isa('PPI::Token::Symbol')) {
                my $var_type = _lookup_var($next_child->content, $env);
                if ($var_type) {
                    my $elem = _unwrap_arrayref($var_type);
                    push @elem_types, $elem if $elem;
                }
                $i += 2;  # skip both Cast and Symbol
                next;
            }
        }

        my $t = __PACKAGE__->infer_expr($child, $env, $elem_expected);
        $i++;
        next unless defined $t;
        # Flatten list types: Array[T] inside [...] contributes T, not Array[T]
        if ($t->is_param && $t->base eq 'Array') {
            push @elem_types, ($t->params)[0];
        } else {
            push @elem_types, $t;
        }
    }

    unless (@elem_types) {
        return $expected if $expected && $expected->is_param && $expected->base eq 'ArrayRef';
        return Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Any'));
    }

    my $common = $elem_types[0];
    for my $i (1 .. $#elem_types) {
        $common = Typist::Subtype->common_super($common, $elem_types[$i]);
    }

    # When bottom-up LUB yields Any (e.g., diverse struct literals),
    # prefer the top-down expected element type if all elements conform
    if ($common->is_atom && $common->name eq 'Any' && $elem_expected) {
        my $registry = $env ? $env->{registry} : undef;
        my $all_conform = 1;
        for my $t (@elem_types) {
            unless (Typist::Subtype->is_subtype($t, $elem_expected,
                    $registry ? (registry => $registry) : ())) {
                $all_conform = 0;
                last;
            }
        }
        $common = $elem_expected if $all_conform;
    }

    Typist::Type::Param->new('ArrayRef', $common);
}

sub _infer_hash ($constructor, $env = undef, $expected = undef) {
    my $expr = $constructor->find_first('PPI::Statement::Expression')
            // $constructor->find_first('PPI::Statement');
    return undef unless $expr;

    # Must contain => to be recognized as a hash (not a block)
    my $has_fat_comma = $expr->find_first(sub {
        $_[1]->isa('PPI::Token::Operator') && $_[1]->content eq '=>'
    });
    return undef unless $has_fat_comma;

    # Resolve alias on expected type (e.g., ReportNode → Struct(...))
    if ($expected && $expected->is_alias && $env && $env->{registry}) {
        my $resolved = $env->{registry}->lookup_type($expected->alias_name);
        $expected = $resolved if $resolved;
    }

    # Expand Handler[E] to Record(op => Func, ...) for bidirectional inference
    if ($expected && $expected->is_param && $expected->base eq 'Handler'
        && scalar($expected->params) == 1 && $env && $env->{registry}) {
        my $expanded = Typist::Subtype::expand_handler($expected, $env->{registry});
        $expected = $expanded if $expanded;
    }

    # Build field-level expected types from Struct
    my %field_expected;
    if ($expected && $expected->is_record) {
        %field_expected = %{$expected->required_ref};
        my $opt = $expected->optional_ref // +{};
        %field_expected = (%field_expected, %$opt);
    }

    # Split children into comma-separated groups to handle multi-token values
    # (e.g., ProductId("WIDGET") = Word + List = 2 tokens)
    my @groups = split_comma_groups($expr->schildren);

    # Process each group as key => value
    my %fields;
    my @val_types;
    my $all_keys_known = 1;

    for my $group (@groups) {
        # Find => in this group
        my $arrow_idx;
        for my $j (0 .. $#$group) {
            if ($group->[$j]->isa('PPI::Token::Operator') && $group->[$j]->content eq '=>') {
                $arrow_idx = $j;
                last;
            }
        }
        next unless defined $arrow_idx && $arrow_idx > 0;

        my $key_name = _extract_hash_key_name($group->[0]);
        $all_keys_known = 0 unless defined $key_name;

        # Value is the first element after =>; infer_expr navigates siblings for multi-token
        my $val_token = $group->[$arrow_idx + 1];
        next unless $val_token;

        my $val_expected = defined $key_name ? $field_expected{$key_name} : undef;
        my $t = __PACKAGE__->infer_expr($val_token, $env, $val_expected);
        if (defined $t) {
            push @val_types, $t;
            $fields{$key_name} = $t if defined $key_name;
        }
    }

    # When all keys are statically known, return Struct
    if ($all_keys_known && %fields) {
        return Typist::Type::Record->new(%fields);
    }

    # Fallback: HashRef[Str, CommonType]
    my $str_type = Typist::Type::Atom->new('Str');

    return Typist::Type::Param->new('HashRef', $str_type, Typist::Type::Atom->new('Any'))
        unless @val_types;

    my $common = $val_types[0];
    for my $j (1 .. $#val_types) {
        $common = Typist::Subtype->common_super($common, $val_types[$j]);
    }

    Typist::Type::Param->new('HashRef', $str_type, $common);
}

# Extract key name from fat-comma left-hand side (bareword or quoted string)
sub _extract_hash_key_name ($token) {
    return $token->content if $token->isa('PPI::Token::Word');
    if ($token->isa('PPI::Token::Quote')) {
        return $token->can('string') ? $token->string : $token->content;
    }
    undef;
}

1;
