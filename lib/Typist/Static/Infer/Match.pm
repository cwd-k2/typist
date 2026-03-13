package Typist::Static::Infer;
use v5.40;

# ── Match Expression Inference ───────────────────
#
# Walks siblings after `match` to find all handler blocks (sub { ... }),
# infers each handler's return type, then computes the union/LUB.
# When the matched value resolves to a Data type, propagates variant
# inner types to arm callbacks.

sub _resolve_data_type ($type, $env) {
    return (undef, undef) unless $type && $env && $env->{registry};
    my $registry = $env->{registry};

    # Direct Data object (rare in static analysis, but possible)
    if ($type->is_data) {
        my $dt = $registry->lookup_datatype($type->name);
        return (undef, undef) unless $dt;
        my %bindings;
        my @params = $dt->type_params;
        my @args   = $type->type_args;
        for my $i (0 .. $#params) {
            $bindings{$params[$i]} = $args[$i] if $i <= $#args && $args[$i];
        }
        return ($dt, \%bindings);
    }

    # Param type: Result[Int] → base 'Result', params [Int]
    if ($type->is_param) {
        my $base_name = $type->base;
        $base_name = "$base_name" if ref $base_name;
        my $dt = $registry->lookup_datatype($base_name);
        return (undef, undef) unless $dt;
        my %bindings;
        my @params     = $dt->type_params;
        my @type_args  = $type->params;
        for my $i (0 .. $#params) {
            $bindings{$params[$i]} = $type_args[$i] if $i <= $#type_args && $type_args[$i];
        }
        return ($dt, \%bindings);
    }

    # Alias: resolve through registry, recurse
    if ($type->is_alias) {
        my $resolved = eval { $registry->lookup_type($type->alias_name) };
        if ($resolved && !$resolved->is_alias) {
            return _resolve_data_type($resolved, $env);
        }
    }

    # Atom: non-parameterized ADT (e.g., Shape, OrderStatus)
    if ($type->is_atom) {
        my $dt = $registry->lookup_datatype($type->name);
        return ($dt, +{}) if $dt;
    }

    (undef, undef);
}

# Build expected Func type for a match arm callback from variant definition.
sub _build_match_arm_expected ($data_def, $tag, $bindings, $outer_expected) {
    return undef unless $data_def && $tag;
    return undef if $tag eq '_';

    my $variants = $data_def->variants;
    return undef unless $variants && exists $variants->{$tag};

    my @variant_types = @{$variants->{$tag}};
    return undef unless @variant_types;

    # Substitute type variable bindings for parameterized ADTs
    if ($bindings && %$bindings) {
        @variant_types = map { $_->substitute($bindings) } @variant_types;
    }

    my $ret = $outer_expected // Typist::Type::Atom->new('Any');
    Typist::Type::Func->new(\@variant_types, $ret);
}

sub _infer_match_return ($match_word, $env, $expected = undef) {
    # Infer matched value type and resolve to Data definition
    my $val_sib = $match_word->snext_sibling;
    my ($data_def, $bindings);

    if ($val_sib && $env) {
        my $val_type = __PACKAGE__->infer_expr($val_sib, $env);
        ($data_def, $bindings) = _resolve_data_type($val_type, $env) if $val_type;
    }

    my @arm_types;
    my $sib = $match_word->snext_sibling;
    my $current_tag;

    while ($sib) {
        last if $sib->isa('PPI::Token::Structure') && $sib->content eq ';';

        # Track current tag: Word(TagName) or Magic(_) followed by =>
        # PPI parses `_` as PPI::Token::Magic (special filehandle),
        # so we must also check for it as the match fallback arm.
        if (($sib->isa('PPI::Token::Word') && $sib->content ne 'sub')
            || ($sib->isa('PPI::Token::Magic') && $sib->content eq '_'))
        {
            my $after_tag = $sib->snext_sibling;
            if ($after_tag && $after_tag->isa('PPI::Token::Operator') && $after_tag->content eq '=>') {
                $current_tag = $sib->content;
            }
        }

        # Look for Word("sub") followed by optional signature then Block
        if ($sib->isa('PPI::Token::Word') && $sib->content eq 'sub') {
            my $after = $sib->snext_sibling;
            # Skip signature: PPI::Token::Prototype or PPI::Structure::List
            if ($after && ($after->isa('PPI::Token::Prototype')
                        || $after->isa('PPI::Structure::List')))
            {
                $after = $after->snext_sibling;
            }
            if ($after && $after->isa('PPI::Structure::Block')) {
                my $arm_expected;
                if ($data_def && $current_tag) {
                    $arm_expected = _build_match_arm_expected(
                        $data_def, $current_tag, $bindings, $expected,
                    );
                }

                my $arm_type;
                if ($arm_expected) {
                    # Use _infer_anon_sub to get full bidirectional inference
                    my $func = _infer_anon_sub($sib, $env, $arm_expected);
                    $arm_type = $func->returns if $func && $func->is_func;
                } else {
                    $arm_type = _infer_block_return($after, $env, $expected);
                }
                push @arm_types, $arm_type if defined $arm_type;
            }
        }

        $sib = $sib->snext_sibling;
    }

    return undef unless @arm_types;
    return $arm_types[0] if @arm_types == 1;

    # If $expected is available, check if all arms conform to it.
    # Check original types first (preserves literal precision for union expected types),
    # then fall back to widened types (for atom expected types like Int, Str).
    if ($expected) {
        my $registry = $env ? $env->{registry} : undef;
        my @sub_args = $registry ? (registry => $registry) : ();
        my $all_conform = 1;
        for my $t (@arm_types) {
            unless (Typist::Subtype->is_subtype($t, $expected, @sub_args)
                    || ($t->is_literal && Typist::Subtype->is_subtype(
                        Typist::Type::Atom->new($t->base_type), $expected, @sub_args))) {
                $all_conform = 0;
                last;
            }
        }
        return $expected if $all_conform;
    }

    # Widen literals to base atoms (consistent with _infer_ternary)
    my @widened = map {
        $_->is_literal ? Typist::Type::Atom->new($_->base_type) : $_
    } @arm_types;

    # LUB
    my $result = $widened[0];
    for my $i (1 .. $#widened) {
        $result = Typist::Subtype->common_super($result, $widened[$i]);
    }

    # If LUB has free vars and $expected is available, prefer $expected
    if ($expected && $result->free_vars) {
        my $registry = $env ? $env->{registry} : undef;
        my $all_ok = 1;
        for my $t (@widened) {
            unless (Typist::Subtype->is_subtype($t, $expected,
                    $registry ? (registry => $registry) : ())) {
                $all_ok = 0;
                last;
            }
        }
        return $expected if $all_ok;
    }

    # If LUB is too coarse (Any), try Union instead
    if ($result->is_atom && $result->name eq 'Any' && @widened <= 4) {
        my @unique;
        for my $w (@widened) {
            push @unique, $w unless grep { $_->equals($w) } @unique;
        }
        return @unique == 1 ? $unique[0] : Typist::Type::Union->new(@unique);
    }

    $result;
}

1;
