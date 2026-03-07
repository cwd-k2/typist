package Typist::Static::TypeEnv;
use v5.40;

our $VERSION = '0.01';

use Scalar::Util 'refaddr';
use Typist::Attribute;
use Typist::Static::Extractor;
use Typist::Static::Infer;
use Typist::Static::NarrowingEngine;
use Typist::Parser;
use Typist::Type::Atom;
use Typist::Type::Param;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        registry         => $args{registry},
        extracted        => $args{extracted},
        ppi_doc          => $args{ppi_doc},
        narrowing        => Typist::Static::NarrowingEngine->new(
                                registry => $args{registry},
                            ),
        _loop_var_types  => +{},
        _local_var_types => +{},
        _infer_log       => [],
        _fn_env_cache    => +{},
    }, $class;
}

# ── Accessors ────────────────────────────────────

sub registry                ($self) { $self->{registry} }
sub ppi_doc                 ($self) { $self->{ppi_doc} }
sub env                     ($self) { $self->{env} }
sub loop_var_types          ($self) { $self->{_loop_var_types} }
sub local_var_types         ($self) { $self->{_local_var_types} }
sub infer_log               ($self) { $self->{_infer_log} }
sub narrowed_var_types      ($self) { $self->{narrowing}->narrowed_vars }
sub narrowed_accessor_types ($self) { $self->{narrowing}->narrowed_accessors }

# ── Public API ───────────────────────────────────

sub build ($self) {
    $self->{env} = $self->_build_env;
    $self->{_fn_env_cache} = +{};
    $self->_collect_loop_var_types;
    $self->_collect_local_var_types;
    $self->{narrowing}->collect_accessor_narrowings($self->{ppi_doc});
}

sub resolve_type ($self, $expr) {
    return undef unless defined $expr;
    my $parsed = eval { Typist::Parser->parse($expr) };
    return undef if $@;

    # Resolve aliases through the local registry
    if ($parsed->is_alias) {
        my $resolved = $self->{registry}->lookup_type($parsed->alias_name);
        return $resolved if $resolved;
    }

    $parsed;
}

# Build a function-scoped env: base env + parameter bindings.
sub fn_env ($self, $fn) {
    my $base = $self->{env};
    my $names  = $fn->{param_names}  // [];
    my $exprs  = $fn->{params_expr}  // [];

    return $base unless @$names;

    # Build bound map for generic type variables: T => Num, etc.
    my %bound_map;
    if ($fn->{generics} && $fn->{generics}->@*) {
        my @generics = $self->_parse_generics($fn->{generics});
        for my $g (@generics) {
            next unless $g->{bound_expr};
            my $bound_type = $self->resolve_type($g->{bound_expr});
            $bound_map{$g->{name}} = $bound_type if $bound_type;
        }
    }

    # Shallow copy variables hash and add parameter bindings
    my %vars = $base->{variables}->%*;
    for my $i (0 .. $#$names) {
        my $expr = $exprs->[$i] // next;
        my $type = $self->resolve_type($expr);
        # For type variables with bounds, substitute the bound type for body checking
        if ($type && $type->is_var && $bound_map{$type->name}) {
            $type = $bound_map{$type->name};
        } elsif (!$type && $bound_map{$expr}) {
            $type = $bound_map{$expr};
        }
        next unless $type;
        $vars{$names->[$i]} = $type;
    }

    +{
        variables => \%vars,
        functions => $base->{functions},
        known     => $base->{known},
        registry  => $base->{registry},
        package   => $base->{package},
    };
}

# Determine the appropriate env for a PPI node.
# If the node is inside a function body, return fn_env with parameter bindings.
# Additionally, narrow the env based on control flow (e.g. `defined` guards).
sub env_for_node ($self, $node) {
    my $env;
    my $ancestor = $node->parent;
    while ($ancestor) {
        if ($ancestor->isa('PPI::Structure::Block')) {
            my $addr = refaddr($ancestor);
            if (exists $self->{_fn_env_cache}{$addr}) {
                $env = $self->{_fn_env_cache}{$addr};
                last;
            }
            # Check if this block belongs to a known function
            my $sub_stmt = $ancestor->parent;
            if ($sub_stmt && $sub_stmt->isa('PPI::Statement::Sub')) {
                my $fn_name = $sub_stmt->name;
                if ($fn_name && $self->{extracted}{functions}{$fn_name}) {
                    my $fn = $self->{extracted}{functions}{$fn_name};
                    if ($fn->{block} && $fn->{block} == $ancestor) {
                        $env = $self->fn_env($fn);
                        $self->{_fn_env_cache}{$addr} = $env;
                        last;
                    }
                }
            }
        }
        $ancestor = $ancestor->parent;
    }
    $env //= $self->{env};

    $env = $self->_inject_loop_vars($env, $node);
    $env = $self->{narrowing}->narrow_env_for_block($env, $node);
    $env = $self->{narrowing}->scan_early_returns($env, $node);
    $env;
}

# ── Environment Construction ─────────────────────

sub _build_env ($self) {
    my (%variables, %functions, %known);

    # Phase 1: annotated variables + all function return types
    for my $var ($self->{extracted}{variables}->@*) {
        next unless $var->{type_expr};
        my $type = $self->resolve_type($var->{type_expr});
        $variables{$var->{name}} = $type if $type;
    }

    for my $name (keys $self->{extracted}{functions}->%*) {
        my $fn = $self->{extracted}{functions}{$name};
        next if $fn->{unannotated};
        $known{$name} = 1;
        if (my $ret_expr = $fn->{returns_expr}) {
            my $type = $self->resolve_type($ret_expr);
            $functions{$name} = $type if $type;
        }
    }

    # Phase 2: unannotated variables — infer from init expression
    # Pre-build function line ranges to skip function-local variables
    # (handled more accurately by _collect_local_var_types with fn-scoped env)
    my @_fn_ranges;
    for my $fn_name (keys $self->{extracted}{functions}->%*) {
        my $fn = $self->{extracted}{functions}{$fn_name};
        push @_fn_ranges, [$fn->{line}, $fn->{end_line}]
            if $fn->{line} && $fn->{end_line};
    }

    my %list_rhs_cache;  # refaddr(init_node) → distributed type arrayref
    my $partial_env = +{
        variables => \%variables,
        functions => \%functions,
        known     => \%known,
        registry  => $self->{registry},
        package   => $self->{extracted}{package} // 'main',
    };

    for my $var ($self->{extracted}{variables}->@*) {
        next if $var->{type_expr};
        next if exists $variables{$var->{name}};

        # Function-local variables: still populate env, but skip infer_log
        # (_collect_local_var_types reports these with proper fn-scoped context)
        my $inside_fn = @_fn_ranges
            && grep { $var->{line} >= $_->[0] && $var->{line} <= $_->[1] } @_fn_ranges;

        my $init_node = $var->{init_node};

        unless ($init_node) {
            unless ($inside_fn) {
                push $self->{_infer_log}->@*, +{
                    name   => $var->{name}, line => $var->{line},
                    type   => undef,        status => 'no_init',
                    scope  => 'top',
                };
            }
            next;
        }

        # Enrich env with enclosing function parameters for accurate inference
        my $infer_env = $self->_scoped_env($partial_env, $init_node);

        # List assignment: use cached RHS type and distribute by position
        if (defined $var->{list_position}) {
            my $addr = refaddr($init_node);
            $list_rhs_cache{$addr} //=
                _distribute_list_type(
                    Typist::Static::Infer->infer_list_rhs_type($init_node, $infer_env),
                    $var->{list_count},
                );
            my $inferred = $list_rhs_cache{$addr}[$var->{list_position}];

            my $status = !defined $inferred  ? 'undef'
                       : ($inferred->is_atom && $inferred->name eq 'Any') ? 'Any_skip'
                       : 'ok';
            my $widened = ($status eq 'ok') ? _widen_literal($inferred) : $inferred;
            unless ($inside_fn) {
                push $self->{_infer_log}->@*, +{
                    name   => $var->{name}, line => $var->{line},
                    type   => $widened ? $widened->to_string : undef,
                    status => $status,
                    scope  => 'top',
                };
            }
            if (defined $inferred && !($inferred->is_atom && $inferred->name eq 'Any')) {
                $variables{$var->{name}} = $widened;
            }
            next;
        }

        # Hash variable with literal init: my %h = (k => v, ...)
        my $inferred;
        if ($var->{name} =~ /\A%/ && $init_node
            && $init_node->isa('PPI::Structure::List'))
        {
            $inferred = _infer_hash_literal_type($init_node, $infer_env);
        }
        # Array variable with list init: my @arr = (elem, ...)
        if (!$inferred && $var->{name} =~ /\A\@/ && $init_node
            && $init_node->isa('PPI::Structure::List'))
        {
            $inferred = _infer_array_literal_type($init_node, $infer_env);
        }
        $inferred //= Typist::Static::Infer->infer_expr_with_siblings($init_node, $infer_env);

        my $status = !defined $inferred  ? 'undef'
                   : ($inferred->is_atom && $inferred->name eq 'Any') ? 'Any_skip'
                   : 'ok';
        my $widened = ($status eq 'ok') ? _widen_literal($inferred) : $inferred;
        unless ($inside_fn) {
            push $self->{_infer_log}->@*, +{
                name   => $var->{name}, line => $var->{line},
                type   => $widened ? $widened->to_string : undef,
                status => $status,
                scope  => 'top',
            };
        }

        next unless defined $inferred;
        next if $inferred->is_atom && $inferred->name eq 'Any';

        $variables{$var->{name}} = $widened;
    }

    $partial_env;
}

# Enrich base env with enclosing function's parameter types.
sub _scoped_env ($self, $base_env, $node) {
    my $parent = $node->parent;
    while ($parent) {
        if ($parent->isa('PPI::Statement::Sub') && $parent->name) {
            my $fn = $self->{extracted}{functions}{$parent->name};
            if ($fn && $fn->{param_names} && @{$fn->{param_names}}) {
                my %vars = $base_env->{variables}->%*;
                my $names = $fn->{param_names};
                my $exprs = $fn->{params_expr} // [];
                for my $i (0 .. $#$names) {
                    my $expr = $exprs->[$i] // next;
                    my $type = $self->resolve_type($expr);
                    next unless $type;
                    $vars{$names->[$i]} = $type;
                }
                return +{ %$base_env, variables => \%vars };
            }
            last;
        }
        $parent = $parent->parent;
    }
    $base_env;
}

# Parse generics_raw strings into structured declarations.
sub _parse_generics ($self, $generics_raw) {
    my @result;
    my @raw_strings;
    for my $g ($generics_raw->@*) {
        if (ref $g eq 'HASH' && exists $g->{name}) {
            push @result, $g;
        } else {
            push @raw_strings, $g;
        }
    }
    if (@raw_strings) {
        my $spec = join(', ', @raw_strings);
        push @result, Typist::Attribute->parse_generic_decl(
            $spec, registry => $self->{registry},
        );
    }
    @result;
}

# ── Loop Variable Support ────────────────────────

# Determine the env for a loop's list node.
sub _env_for_loop_list ($self, $node) {
    my $ancestor = $node->parent;
    while ($ancestor) {
        if ($ancestor->isa('PPI::Structure::Block')) {
            my $sub_stmt = $ancestor->parent;
            if ($sub_stmt && $sub_stmt->isa('PPI::Statement::Sub')) {
                my $fn_name = $sub_stmt->name;
                if ($fn_name && $self->{extracted}{functions}{$fn_name}) {
                    my $fn = $self->{extracted}{functions}{$fn_name};
                    if ($fn->{block} && $fn->{block} == $ancestor) {
                        return $self->fn_env($fn);
                    }
                }
            }
        }
        $ancestor = $ancestor->parent;
    }
    $self->{env};
}

# Walk ancestors to detect enclosing for/foreach loops and inject loop
# variable types into the env.
sub _inject_loop_vars ($self, $env, $node) {
    my @loop_vars;    # collect from outermost to innermost

    my $ancestor = $node;
    while ($ancestor = $ancestor->parent) {
        next unless $ancestor->isa('PPI::Structure::Block');

        my $compound = $ancestor->parent;
        next unless $compound && $compound->isa('PPI::Statement::Compound');

        my $parsed = Typist::Static::Extractor->parse_loop_compound($compound)
            // next;

        # Verify the block matches the ancestor
        next unless $parsed->{block} == $ancestor;

        unshift @loop_vars, $parsed;
    }

    return $env unless @loop_vars;

    my %new_vars = $env->{variables}->%*;
    for my $lv (@loop_vars) {
        my $elem_type = Typist::Static::Infer->infer_iterable_element_type($lv->{list}, $env);
        if ($elem_type) {
            $new_vars{$lv->{var_sym}->content} = $elem_type;

            # Cache for Analyzer symbol index
            my $block_last = $lv->{block}->last_token;
            $self->{_loop_var_types}{$lv->{var_sym}->content . ':' . $lv->{var_sym}->line_number} = +{
                name        => $lv->{var_sym}->content,
                type        => $elem_type,
                line        => $lv->{var_sym}->line_number,
                col         => $lv->{var_sym}->column_number,
                scope_start => $lv->{block}->line_number,
                scope_end   => $block_last ? $block_last->line_number : $lv->{block}->line_number,
            };
        }
    }

    +{ %$env, variables => \%new_vars };
}

# ── Variable Collection ──────────────────────────

# Proactively infer loop variable types from extracted loop_variables.
sub _collect_loop_var_types ($self) {
    my $loops = $self->{extracted}{loop_variables} // [];
    return unless @$loops;

    for my $lv (@$loops) {
        my $list_node = $lv->{list_node} // next;
        my $block_node = $lv->{block_node} // next;

        # Use function-scoped env if loop is inside a function body
        my $env = $self->_env_for_loop_list($list_node);

        my $elem_type = Typist::Static::Infer->infer_iterable_element_type($list_node, $env);
        next unless $elem_type;

        my $block_last = $block_node->last_token;
        my $key = $lv->{name} . ':' . $lv->{line};
        $self->{_loop_var_types}{$key} = +{
            name        => $lv->{name},
            type        => $elem_type,
            line        => $lv->{line},
            col         => $lv->{col},
            scope_start => $lv->{scope_start},
            scope_end   => $lv->{scope_end},
        };
    }
}

# Walk each function body to find unannotated `my $var = EXPR` declarations
# and re-infer them with function-scoped env.
sub _collect_local_var_types ($self) {
    my $ppi_doc   = $self->{ppi_doc} // return;
    my $functions = $self->{extracted}{functions} // return;

    for my $fn_name (keys %$functions) {
        my $fn    = $functions->{$fn_name};
        my $block = $fn->{block} // next;
        next unless $fn->{line} && $fn->{end_line};

        my $stmts = $block->find('PPI::Statement::Variable') || [];
        for my $stmt (@$stmts) {
            next unless ($stmt->type // '') eq 'my';
            my @children = $stmt->schildren;

            # Find $var = EXPR or ($a, $b) = EXPR pattern
            my ($var_name, $var_sym, $init_node);
            my @list_syms;
            for my $i (0 .. $#children) {
                # List pattern: my ($a, $b) = ...
                if ($children[$i]->isa('PPI::Structure::List') && !$var_name && !@list_syms) {
                    my $expr = $children[$i]->find_first('PPI::Statement::Expression')
                            || $children[$i]->find_first('PPI::Statement');
                    if ($expr) {
                        @list_syms = grep { $_->isa('PPI::Token::Symbol') } $expr->schildren;
                    }
                }
                if ($children[$i]->isa('PPI::Token::Symbol') && !$var_name && !@list_syms) {
                    $var_name = $children[$i]->content;
                    $var_sym  = $children[$i];
                }
                if ($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq '=') {
                    $init_node = $children[$i + 1] if $i + 1 <= $#children;
                    last;
                }
            }

            # Skip annotated variables (have :sig attribute)
            my $has_sig = 0;
            for my $i (0 .. $#children) {
                if ($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq ':') {
                    my $nxt = $children[$i + 1] // next;
                    if ($nxt->isa('PPI::Token::Word') && $nxt->content eq 'sig') {
                        $has_sig = 1;
                        last;
                    }
                }
            }
            next if $has_sig;

            # List assignment: my ($a, $b) = expr
            if (@list_syms && $init_node) {
                my $env = $self->fn_env($fn);
                $env = $self->_inject_loop_vars($env, $init_node);
                $env = $self->_inject_anon_sub_params($env, $stmt, $block, $fn);
                if (keys $self->{_local_var_types}->%*) {
                    my %vars = $env->{variables}->%*;
                    for my $lv (values $self->{_local_var_types}->%*) {
                        next unless $lv->{scope_start} == $fn->{line};
                        $vars{$lv->{name}} //= $lv->{type};
                    }
                    $env = +{ $env->%*, variables => \%vars };
                }
                my $distributed = _distribute_list_type(
                    Typist::Static::Infer->infer_list_rhs_type($init_node, $env),
                    scalar @list_syms,
                );
                for my $pos (0 .. $#list_syms) {
                    my $sym = $list_syms[$pos];
                    my $inferred = $distributed->[$pos];
                    my $status = !defined $inferred  ? 'undef'
                               : ($inferred->is_atom && $inferred->name eq 'Any') ? 'Any_skip'
                               : 'ok';
                    my $widened = ($status eq 'ok') ? _widen_literal($inferred) : $inferred;
                    push $self->{_infer_log}->@*, +{
                        name   => $sym->content, line => $sym->line_number,
                        type   => $widened ? $widened->to_string : undef,
                        status => $status,
                        scope  => "fn:$fn_name",
                    };
                    next unless defined $inferred;
                    next if $inferred->is_atom && $inferred->name eq 'Any';

                    my $key = $sym->content . ':' . $sym->line_number;
                    $self->{_local_var_types}{$key} = +{
                        name        => $sym->content,
                        type        => $widened,
                        line        => $sym->line_number,
                        col         => $sym->column_number,
                        scope_start => $fn->{line},
                        scope_end   => $fn->{end_line},
                    };
                }
                next;
            }

            next unless $var_name && $init_node;

            # Use function-scoped env (includes parameter bindings)
            my $env = $self->fn_env($fn);
            $env = $self->_inject_loop_vars($env, $init_node);
            $env = $self->_inject_anon_sub_params($env, $stmt, $block, $fn);

            # Inject previously collected local var types
            if (keys $self->{_local_var_types}->%*) {
                my %vars = $env->{variables}->%*;
                for my $lv (values $self->{_local_var_types}->%*) {
                    next unless $lv->{scope_start} == $fn->{line};
                    $vars{$lv->{name}} //= $lv->{type};
                }
                $env = +{ $env->%*, variables => \%vars };
            }

            # Hash variable with literal init: my %h = (k => v, ...)
            my $inferred;
            if ($var_name =~ /\A%/ && $init_node
                && $init_node->isa('PPI::Structure::List'))
            {
                $inferred = _infer_hash_literal_type($init_node, $env);
            }
            # Array variable with list init: my @arr = (elem, ...)
            if (!$inferred && $var_name =~ /\A\@/ && $init_node
                && $init_node->isa('PPI::Structure::List'))
            {
                $inferred = _infer_array_literal_type($init_node, $env);
            }
            $inferred //= Typist::Static::Infer->infer_expr_with_siblings($init_node, $env);

            my $status = !defined $inferred  ? 'undef'
                       : ($inferred->is_atom && $inferred->name eq 'Any') ? 'Any_skip'
                       : 'ok';
            my $widened = ($status eq 'ok') ? _widen_literal($inferred) : $inferred;
            push $self->{_infer_log}->@*, +{
                name   => $var_name, line => $var_sym->line_number,
                type   => $widened ? $widened->to_string : undef,
                status => $status,
                scope  => "fn:$fn_name",
            };

            next unless defined $inferred;
            next if $inferred->is_atom && $inferred->name eq 'Any';

            my $key = $var_name . ':' . $var_sym->line_number;
            $self->{_local_var_types}{$key} = +{
                name        => $var_name,
                type        => $widened,
                line        => $var_sym->line_number,
                col         => $var_sym->column_number,
                scope_start => $fn->{line},
                scope_end   => $fn->{end_line},
            };
        }
    }
}

# ── Pure Helpers ─────────────────────────────────

# Widen literal types for mutable variable bindings.
sub _widen_literal ($type) {
    if ($type->is_literal) {
        my $base = $type->base_type;
        $base = 'Int' if $base eq 'Bool';
        return Typist::Type::Atom->new($base);
    }
    # Recurse into Param types: Option[42] → Option[Int]
    if ($type->is_param && $type->params) {
        my @args = $type->params;
        my $changed;
        my @widened = map {
            my $w = _widen_literal($_);
            $changed = 1 if !$w->equals($_);
            $w;
        } @args;
        return Typist::Type::Param->new($type->base, @widened) if $changed;
    }
    $type;
}

# Distribute a container type to list-assignment positions.
sub _distribute_list_type ($type, $count) {
    return [(undef) x $count] unless defined $type;

    # Tuple[T1, T2, ...] → positional distribution
    if ($type->is_param && $type->base eq 'Tuple') {
        my @params = $type->params;
        return [map { $params[$_] } 0 .. $count - 1];
    }

    # ArrayRef[T] → all positions get T
    if ($type->is_param && ($type->base eq 'ArrayRef' || $type->base eq 'Array')) {
        my $elem = ($type->params)[0];
        return [($elem) x $count];
    }

    [(undef) x $count];
}

# Infer Array[T] from a list literal: (elem, ...)
# Empty list () → Array[Any].
sub _infer_array_literal_type ($list_node, $env) {
    my $expr = $list_node->find_first('PPI::Statement::Expression')
            // $list_node->find_first('PPI::Statement');

    # Empty list: ()
    unless ($expr) {
        require Typist::Type::Param;
        return Typist::Type::Param->new('Array', Typist::Type::Atom->new('Any'));
    }

    my @children = $expr->schildren;
    # If it has =>, it's a hash literal, not an array
    my $has_fat_comma = grep {
        $_->isa('PPI::Token::Operator') && $_->content eq '=>'
    } @children;
    return undef if $has_fat_comma;

    my @elem_types;
    for my $child (@children) {
        next if $child->isa('PPI::Token::Operator') && $child->content eq ',';
        my $t = Typist::Static::Infer->infer_expr($child, $env);
        $t = _widen_literal($t) if $t;
        push @elem_types, $t if $t;
    }

    require Typist::Type::Param;
    unless (@elem_types) {
        return Typist::Type::Param->new('Array', Typist::Type::Atom->new('Any'));
    }

    my $elem_lub = $elem_types[0];
    for my $i (1 .. $#elem_types) {
        $elem_lub = Typist::Subtype->common_super($elem_lub, $elem_types[$i]);
    }
    Typist::Type::Param->new('Array', $elem_lub);
}

# Infer Hash[Str, V] from a literal list with => pairs: (k => v, ...)
sub _infer_hash_literal_type ($list_node, $env) {
    my $expr = $list_node->find_first('PPI::Statement::Expression')
            // $list_node->find_first('PPI::Statement');
    return undef unless $expr;

    my @children = $expr->schildren;
    # Must have at least one => to be a hash literal
    my $has_fat_comma = grep {
        $_->isa('PPI::Token::Operator') && $_->content eq '=>'
    } @children;
    return undef unless $has_fat_comma;

    # Collect value types (elements after =>)
    my @value_types;
    for my $i (0 .. $#children) {
        next unless $children[$i]->isa('PPI::Token::Operator')
                 && $children[$i]->content eq '=>';
        next unless $i + 1 <= $#children;
        my $val = Typist::Static::Infer->infer_expr($children[$i + 1], $env);
        $val = _widen_literal($val) if $val;
        push @value_types, $val if $val;
    }
    return undef unless @value_types;

    # LUB of all value types
    my $value_lub = $value_types[0];
    for my $i (1 .. $#value_types) {
        $value_lub = Typist::Subtype->common_super($value_lub, $value_types[$i]);
    }

    require Typist::Type::Param;
    Typist::Type::Param->new('Hash', Typist::Type::Atom->new('Str'), $value_lub);
}

# ── Anonymous Sub Parameter Injection ────────────
#
# Walk ancestors from $node up to $fn_block, detecting enclosing anonymous
# subs and injecting their parameter types into the env.  Handles three
# patterns:  match arms, HOF callbacks, and return closures.

sub _inject_anon_sub_params ($self, $env, $node, $fn_block, $fn) {
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
    $env;
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
    my $expr = $container->find_first('PPI::Statement::Expression')
            || $container->find_first('PPI::Statement');
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

__END__

=head1 NAME

Typist::Static::TypeEnv - Type environment construction for static analysis

=head1 DESCRIPTION

Builds and manages the type environment used by static analysis.  Extracted
from L<Typist::Static::TypeChecker> to separate environment construction
from type checking.

=head2 new

    my $type_env = Typist::Static::TypeEnv->new(
        registry  => $registry,
        extracted => $extracted,
        ppi_doc   => $ppi_doc,
    );

=head2 build

    $type_env->build;

Build the type environment: resolve annotations, infer unannotated
variable types, collect loop and local variable types, and run accessor
narrowing.

=head2 env

Return the built type environment hashref.

=head2 env_for_node

Return the appropriate env for a PPI node, including function parameter
bindings, loop variable injection, and control-flow narrowing.

=head2 fn_env

Return a function-scoped env with parameter type bindings.

=head2 resolve_type

Parse a type expression string and resolve aliases through the registry.

=cut
