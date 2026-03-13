package Typist::Static::Infer;
use v5.40;

# ── Function Call Inference + Generic Instantiation ─
#
# Resolves function call return types via local env, registry, and
# builtins. Includes generic type variable binding from argument
# inference and struct constructor instantiation.

# Extract the first string argument from a PPI::Structure::List.
# Returns the unquoted string or undef.
sub _extract_first_string_arg ($list_node) {
    my $expr = $list_node->find_first('PPI::Token::Quote') || return undef;
    $expr->string;
}

sub _infer_call ($name, $env, $list_element = undef, $expected = undef) {
    return undef unless $env;

    # scoped('State[Int]') → Atom('EffectScope[State[Int]]')
    if ($name eq 'scoped' && $list_element) {
        my $arg_str = _extract_first_string_arg($list_element);
        if ($arg_str && $arg_str =~ /\A\w+/) {
            return Typist::Type::Atom->new("EffectScope[$arg_str]");
        }
        return Typist::Type::Atom->new('Any');
    }

    # Local function with known return type
    if (my $ret = $env->{functions}{$name}) {
        # Generic local functions: instantiate via registry sig when args present
        if ($ret->free_vars && $list_element && $env->{registry}) {
            my $pkg = $env->{package} // 'main';
            my $sig = $env->{registry}->lookup_function($pkg, $name);
            if ($sig && $sig->{generics} && @{$sig->{generics}}) {
                return _maybe_instantiate_return($sig, $env, $list_element, $expected);
            }
        }
        return $ret;
    }

    # Partially annotated (has annotations but no :Returns) → unknown
    return undef if $env->{known} && $env->{known}{$name};

    # Cross-package: Pkg::func → registry lookup
    if ($name =~ /\A(.+)::(\w+)\z/) {
        my ($pkg, $fname) = ($1, $2);
        my $registry = $env->{registry};
        if ($registry) {
            my $sig = $registry->lookup_function($pkg, $fname);
            if ($sig && $sig->{returns}) {
                return _maybe_instantiate_return($sig, $env, $list_element, $expected);
            }
            # Registered but no return type → partially annotated
            return undef if $sig;
        }
    }

    # Builtin fallback: CORE::name from prelude or declare
    if (my $registry = $env->{registry}) {
        my $core_sig = $registry->lookup_function('CORE', $name);
        if ($core_sig && $core_sig->{returns}) {
            return $core_sig->{generics} && @{$core_sig->{generics}}
                ? _maybe_instantiate_return($core_sig, $env, $list_element, $expected)
                : $core_sig->{returns};
        }
    }

    # Current-package function (e.g., ADT constructor registered by Analyzer)
    if (my $registry = $env->{registry}) {
        my $pkg = $env->{package} // 'main';
        my $pkg_sig = $registry->lookup_function($pkg, $name);
        if ($pkg_sig && $pkg_sig->{returns}) {
            return _maybe_instantiate_return($pkg_sig, $env, $list_element, $expected);
        }
    }

    # Cross-package fallback: Exporter-imported constructors (Regular, Ok, Err, etc.)
    if (my $registry = $env->{registry}) {
        if (my $sig = $registry->search_function_by_name($name)) {
            if ($sig->{returns}) {
                my $ret = _maybe_instantiate_return($sig, $env, $list_element, $expected);
                # Bidirectional: bind remaining free vars from expected type.
                # Handles: None() -> Option[T] with expected Option[Str] → Option[Str]
                if ($ret->free_vars && $expected) {
                    my %extra;
                    if (Typist::Static::Unify->collect_bindings($ret, $expected, \%extra) && %extra) {
                        $ret = $ret->substitute(\%extra);
                    }
                }
                # Replace remaining unresolved type vars with '_' placeholder.
                if ($ret->free_vars) {
                    require Typist::Type::Fold;
                    $ret = Typist::Type::Fold->map_type($ret, sub ($t) {
                        $t->is_var ? Typist::Type::Atom->new('_') : $t;
                    });
                }
                return $ret;
            }
        }
    }

    # Completely unannotated → Any (gradual typing)
    Typist::Type::Atom->new('Any');
}

# For generic functions (incl. GADT constructors), resolve type variables
# in the return type by unifying formal param types against inferred arg types.
sub _maybe_instantiate_return ($sig, $env, $list_element, $expected = undef) {
    my $ret = $sig->{returns};
    my $generics = $sig->{generics};

    # No generics or no argument list → return as-is
    return $ret unless $generics && @$generics && $list_element;

    # Generic struct constructor: named-arg binding
    if ($sig->{struct_constructor} && $ret->is_struct && $ret->type_params) {
        return _instantiate_generic_struct($ret, $env, $list_element, $expected);
    }

    my @params = $sig->{params} && @{$sig->{params}} ? @{$sig->{params}} : ();

    # Extract PPI argument nodes
    # PPI wraps argument lists as Statement::Expression (multi-arg) or
    # plain Statement (single complex arg like [...]/{...}).
    # Anonymous subs are split by PPI into sub + Prototype + Block;
    # we keep only the 'sub' token and skip its continuations, since
    # infer_expr(sub_token) walks snext_sibling internally.
    my @arg_nodes;
    if (@params) {
        my $expr = $list_element->schild(0);
        if ($expr && $expr->isa('PPI::Statement')) {
            my @children = $expr->schildren;
            my $i = 0;
            while ($i <= $#children) {
                my $child = $children[$i];
                if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
                    $i++; next;
                }
                push @arg_nodes, $child;
                # Skip anonymous sub continuations (Prototype/List + Block)
                if ($child->isa('PPI::Token::Word') && $child->content eq 'sub'
                    && !($child->parent && $child->parent->isa('PPI::Statement::Sub'))) {
                    $i++;
                    # Skip signature (Prototype or List)
                    if ($i <= $#children && ($children[$i]->isa('PPI::Token::Prototype')
                                          || $children[$i]->isa('PPI::Structure::List'))) {
                        $i++;
                    }
                    # Skip block
                    if ($i <= $#children && $children[$i]->isa('PPI::Structure::Block')) {
                        $i++;
                    }
                    next;
                }
                # Skip function call argument list: Word + List forms a single call.
                # infer_expr(Word) follows snext_sibling to discover the List.
                if ($child->isa('PPI::Token::Word') && $child->content ne 'sub'
                    && $i + 1 <= $#children
                    && $children[$i + 1]->isa('PPI::Structure::List'))
                {
                    $i += 2;
                    next;
                }
                $i++;
            }
        }

        # No args and no expected type to bind from → return as-is
        return $ret unless @arg_nodes || $expected;
    }

    my %bindings;

    # Pass 1: infer all args without expected, collect initial bindings
    for my $i (0 .. $#params) {
        last if $i > $#arg_nodes;
        my $t = __PACKAGE__->infer_expr($arg_nodes[$i], $env);
        if ($t) {
            Typist::Static::Unify->collect_bindings($params[$i], $t, \%bindings);
        }
    }

    # Pass 2: re-infer callback args with substituted formal type as expected.
    # Activates when Pass 1 produced bindings, OR when there are Func params
    # (bidirectional inference can discover bindings from callback bodies even
    # when Pass 1 failed — e.g., kleisli(sub { ... }, sub { ... })).
    my $has_func_params = grep { $_->is_func } @params;
    if (%bindings || $has_func_params) {
        for my $i (0 .. $#params) {
            last if $i > $#arg_nodes;
            next unless $params[$i]->is_func;
            my $expected = $params[$i]->substitute(\%bindings);
            my $refined = __PACKAGE__->infer_expr($arg_nodes[$i], $env, $expected);
            if ($refined) {
                Typist::Static::Unify->collect_bindings(
                    $params[$i], $refined, \%bindings);
            }
        }
    }

    my $result = %bindings ? $ret->substitute(\%bindings) : $ret;
    my $any_bound = !!%bindings;

    # Pass 3: bind remaining free vars from expected type (bidirectional).
    # This handles cases like Err("msg") -> Result[T] where T can't be
    # bound from arguments but CAN be bound from the expected return type.
    # Guard: only when result and expected share the same Param base,
    # to avoid incorrect binding like Expr[A] + Int → Expr[Int].
    if ($expected && $result->free_vars
        && $result->is_param && $expected->is_param
        && "${\$result->base}" eq "${\$expected->base}") {
        my %extra;
        if (Typist::Static::Unify->collect_bindings($result, $expected, \%extra) && %extra) {
            $result = $ret->substitute(+{ %bindings, %extra });
            $any_bound = 1;
        }
    }

    # Fallback: replace remaining free vars with placeholder '_'.
    # Only when at least one binding was made — if nothing was bound,
    # preserve live Vars so TypeChecker can detect type mismatches.
    if ($result->free_vars && $any_bound) {
        require Typist::Type::Fold;
        $result = Typist::Type::Fold->map_type($result, sub ($t) {
            $t->is_var ? Typist::Type::Atom->new('_') : $t;
        });
    }

    $result;
}

# Instantiate a generic struct constructor from named arguments.
# Extracts key => value pairs from PPI, infers value types, and
# collects bindings from formal field types.
sub _instantiate_generic_struct ($struct_type, $env, $list_element, $expected = undef) {
    my $record = $struct_type->record;
    my $req = $record->required_ref;
    my $opt = $record->optional_ref;
    my %all = (%$req, %$opt);

    # Extract key => value pairs from the PPI List
    my $expr = $list_element->schild(0);
    $expr = $expr->schild(0) if $expr && $expr->isa('PPI::Statement::Expression')
                              && $expr->schildren == 1
                              && $expr->schild(0)->isa('PPI::Structure::List');
    return $struct_type unless $expr;

    # Get the expression node (may be inside Statement::Expression)
    my $target = $expr;
    if ($target->isa('PPI::Statement::Expression')) {
        # Use it directly — children are the tokens
    } elsif ($target->isa('PPI::Structure::List')) {
        $target = $target->schild(0) // return $struct_type;
    }

    # Split into comma-separated groups and collect bindings
    my %bindings;
    my @children = $target->schildren;
    my @current;
    for my $child (@children) {
        if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
            _bind_struct_field(\@current, \%all, \%bindings, $env) if @current;
            @current = ();
        } else {
            push @current, $child;
        }
    }
    _bind_struct_field(\@current, \%all, \%bindings, $env) if @current;

    # Widen literal bindings: Literal(42, Int) → Atom(Int)
    for my $k (keys %bindings) {
        my $v = $bindings{$k};
        if ($v->is_literal) {
            my $base = $v->base_type;
            $base = 'Int' if $base eq 'Bool';
            $bindings{$k} = Typist::Type::Atom->new($base);
        }
    }

    # Substitute bindings into the struct type
    if (%bindings) {
        my @tp = $struct_type->type_params;
        my @type_args = map {
            $bindings{$_} // Typist::Type::Atom->new('_')
        } @tp;
        return $struct_type->substitute(\%bindings)->instantiate(@type_args)
            if @tp;
    }

    $struct_type;
}

# Helper: extract field name and value from a key => value group,
# infer the value type, and collect bindings.
sub _bind_struct_field ($group, $all_fields, $bindings, $env) {
    # Find => in this group
    my $arrow_idx;
    for my $j (0 .. $#$group) {
        if ($group->[$j]->isa('PPI::Token::Operator') && $group->[$j]->content eq '=>') {
            $arrow_idx = $j;
            last;
        }
    }
    return unless defined $arrow_idx && $arrow_idx > 0;

    my $key_tok = $group->[0];
    my $field_name;
    if ($key_tok->isa('PPI::Token::Word')) {
        $field_name = $key_tok->content;
    } elsif ($key_tok->isa('PPI::Token::Quote')) {
        $field_name = $key_tok->string;
    }
    return unless defined $field_name && exists $all_fields->{$field_name};

    my $val_token = $group->[$arrow_idx + 1] // return;
    my $formal = $all_fields->{$field_name};
    my $inferred = __PACKAGE__->infer_expr($val_token, $env, $formal);
    return unless $inferred;

    Typist::Static::Unify->collect_bindings($formal, $inferred, $bindings);
}

1;
