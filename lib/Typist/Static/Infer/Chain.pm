package Typist::Static::Infer;
use v5.40;

# ── Subscript & Accessor Chain Inference ─────────
#
# Chases $var->{key}->method->[0] chains, resolving each link
# via struct field types, method return types, and subscript access.

sub _infer_subscript_access ($var_type, $subscript) {
    my $braces = $subscript->braces;

    # Array subscript: $arr->[idx] — ArrayRef[T] → T
    if ($braces eq '[]') {
        if ($var_type->is_param && $var_type->base eq 'ArrayRef') {
            return ($var_type->params)[0];
        }
        return undef;
    }

    # Hash/Struct subscript: $h->{key}
    if ($braces eq '{}') {
        # HashRef[K, V] or Hash[K, V] → V
        if ($var_type->is_param && ($var_type->base eq 'HashRef' || $var_type->base eq 'Hash')) {
            return ($var_type->params)[1];
        }

        # Struct → field type lookup
        if ($var_type->is_record) {
            my $key = _extract_subscript_key($subscript);
            return undef unless defined $key;

            # Check required fields, then optional fields
            return $var_type->required_ref->{$key} // $var_type->optional_ref->{$key};
        }
    }

    undef;
}

sub _extract_subscript_key ($subscript) {
    # Find the meaningful token inside { ... } or [ ... ]
    my $inner = $subscript->find_first('PPI::Statement::Expression')
             // $subscript->find_first('PPI::Statement');
    return undef unless $inner;

    my $token = $inner->schild(0);
    return undef unless $token;

    # Bare word: {key}
    return $token->content if $token->isa('PPI::Token::Word');

    # Quoted string: {'key'} or {"key"}
    if ($token->isa('PPI::Token::Quote')) {
        return $token->can('string') ? $token->string : $token->content;
    }

    undef;
}

# Walk past an accessor chain from $start, returning the first PPI token
# after the chain (or undef if chain extends to end of siblings).
# Used by infer_expr_with_siblings to find trailing operators.
sub _skip_accessor_chain ($start) {
    my $node = $start->snext_sibling;
    while ($node) {
        last unless $node->isa('PPI::Token::Operator') && $node->content eq '->';
        my $next = $node->snext_sibling;
        last unless $next;
        if ($next->isa('PPI::Token::Word') || $next->isa('PPI::Structure::Subscript')) {
            my $after = $next->snext_sibling;
            if ($after && $after->isa('PPI::Structure::List')) {
                $node = $after->snext_sibling;
            } else {
                $node = $after;
            }
            next;
        }
        if ($next->isa('PPI::Structure::List')) {
            $node = $next->snext_sibling;
            next;
        }
        last;
    }
    $node;
}

sub _chase_subscript_chain ($type, $start_node, $env = undef) {
    return $type unless defined $type;

    # Narrowing tree cursor: walks in lockstep with the accessor chain
    my $nc = ($env && $env->{narrowed_accessors} && $start_node->isa('PPI::Token::Symbol'))
        ? $env->{narrowed_accessors}{$start_node->content}
        : undef;

    my $node = $start_node->snext_sibling;
    while ($node) {
        # Adjacent subscript without arrow: $h->{key}[0] (Perl allows omitting -> between subscripts)
        if ($node->isa('PPI::Structure::Subscript')) {
            $type = _infer_subscript_access($type, $node);
            last unless defined $type;
            $nc = undef;  # subscript breaks accessor narrowing path
            $node = $node->snext_sibling;
            next;
        }

        last unless $node->isa('PPI::Token::Operator') && $node->content eq '->';
        my $next = $node->snext_sibling;
        last unless $next;

        # -> Subscript: $h->{key}, $a->[0]
        if ($next->isa('PPI::Structure::Subscript')) {
            $type = _infer_subscript_access($type, $next);
            last unless defined $type;
            $nc = undef;  # subscript breaks accessor narrowing path
            $node = $next->snext_sibling;
            next;
        }

        # -> Word: method call / struct accessor
        if ($next->isa('PPI::Token::Word')) {
            $type = _infer_method_access($type, $next, $env);
            last unless defined $type;
            # Apply accessor narrowing from defined() guards (nested tree walk)
            if ($nc) {
                my $acc_name = $next->content;
                my $subtree = $nc->{$acc_name};
                if (ref $subtree eq 'HASH' && $subtree->{__type__}) {
                    $type = $subtree->{__type__};
                }
                $nc = $subtree;
            }
            # Skip past optional argument list: ->method(...)
            my $after = $next->snext_sibling;
            if ($after && $after->isa('PPI::Structure::List')) {
                $node = $after->snext_sibling;
            } else {
                $node = $after;
            }
            next;
        }

        # -> List: CodeRef application $f->(args)
        if ($next->isa('PPI::Structure::List') && $type->is_func) {
            if ($type->free_vars) {
                my @params = $type->params;
                my %bindings;
                my @arg_nodes;
                my $expr = $next->schild(0);
                if ($expr && $expr->isa('PPI::Statement')) {
                    my @children = $expr->schildren;
                    my $ci = 0;
                    while ($ci <= $#children) {
                        my $child = $children[$ci];
                        if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
                            $ci++; next;
                        }
                        push @arg_nodes, $child;
                        if ($child->isa('PPI::Token::Word') && $child->content eq 'sub'
                            && !($child->parent && $child->parent->isa('PPI::Statement::Sub'))) {
                            $ci++;
                            if ($ci <= $#children && ($children[$ci]->isa('PPI::Token::Prototype')
                                                   || $children[$ci]->isa('PPI::Structure::List'))) {
                                $ci++;
                            }
                            if ($ci <= $#children && $children[$ci]->isa('PPI::Structure::Block')) {
                                $ci++;
                            }
                            next;
                        }
                        # Skip function call argument list
                        if ($child->isa('PPI::Token::Word') && $child->content ne 'sub'
                            && $ci + 1 <= $#children
                            && $children[$ci + 1]->isa('PPI::Structure::List'))
                        {
                            $ci += 2;
                            next;
                        }
                        $ci++;
                    }
                }

                # Pass 1: infer all args without expected, collect bindings
                for my $i (0 .. $#params) {
                    last if $i > $#arg_nodes;
                    my $t = __PACKAGE__->infer_expr($arg_nodes[$i], $env);
                    Typist::Static::Unify->collect_bindings($params[$i], $t, \%bindings) if $t;
                }

                # Pass 2: re-infer callback args with substituted expected type
                if (%bindings) {
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

                $type = %bindings ? $type->returns->substitute(\%bindings) : $type->returns;
            } else {
                $type = $type->returns;
            }
            # Parameterized types with free vars (e.g. Result[B]) are kept:
            # their outer structure is concrete and useful for inference.
            # Naked type vars (e.g. A from generic callbacks) are also kept —
            # TypeChecker skips type-var checks via _has_type_var.
            $node = $next->snext_sibling;
            next;
        }

        last;
    }

    $type;
}

# Infer the return type of a method call or struct accessor.
# For struct types, field accessors return the field type.
# For with(), returns the same struct type.
sub _infer_method_access ($receiver_type, $method_word, $env = undef) {
    my $method_name = $method_word->content;

    # Resolve alias/atom name to concrete type (e.g., Alias("Customer") → Struct)
    my $resolved = $receiver_type;
    if ($resolved->is_alias && $env && $env->{registry}) {
        my $looked_up = $env->{registry}->lookup_type($resolved->alias_name);
        $resolved = $looked_up if $looked_up;
    }
    # Resolve atom name (e.g., Atom("Product") from match arm param injection)
    if ($resolved->is_atom && $env && $env->{registry}) {
        my $looked_up = eval { $env->{registry}->lookup_type($resolved->name) };
        $resolved = $looked_up if $looked_up && !$looked_up->is_atom;
    }

    # Newtype: no instance methods
    if ($resolved->is_newtype) {
        return undef;
    }

    # EffectScope: resolve method to effect operation return type
    if ($resolved->is_atom && $resolved->name =~ /\AEffectScope\[(\w+)/) {
        my $effect_name = $1;
        if ($env && $env->{registry}) {
            my $eff = $env->{registry}->lookup_effect($effect_name);
            if ($eff) {
                my $op_type = $eff->get_op_type($method_name);
                return $op_type->returns if $op_type && $op_type->is_func;
                # Operation exists but unparseable → Any
                return Typist::Type::Atom->new('Any') if $eff->get_op($method_name);
            }
        }
        return undef;
    }

    # Struct accessor: resolve field type from the inner record
    if ($resolved->is_struct) {
        my $record = $resolved->record;
        my $req = $record->required_ref;
        my $opt = $record->optional_ref;

        my $field_type;
        if (exists $req->{$method_name}) {
            $field_type = $req->{$method_name};
        } elsif (exists $opt->{$method_name}) {
            $field_type = Typist::Type::Union->new(
                $opt->{$method_name}, Typist::Type::Atom->new('Undef'),
            );
        }
        if ($field_type) {
            # Generic struct: substitute type_params → type_args
            if ($resolved->type_params && $resolved->type_args) {
                my @tp = $resolved->type_params;
                my @ta = $resolved->type_args;
                if (@tp == @ta) {
                    my %bindings;
                    $bindings{$tp[$_]} = $ta[$_] for 0 .. $#tp;
                    $field_type = $field_type->substitute(\%bindings);
                }
            }
            return $field_type;
        }

    }

    # Fallback: look up method in registry if available
    if ($env && $env->{registry}) {
        my $pkg = ref $resolved && $resolved->is_struct
            ? $resolved->package : undef;
        if ($pkg) {
            my $sig = $env->{registry}->lookup_method($pkg, $method_name);
            return $sig->{returns} if $sig && $sig->{returns};
        }
    }

    undef;
}

1;
