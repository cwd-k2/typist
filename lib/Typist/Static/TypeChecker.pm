package Typist::Static::TypeChecker;
use v5.40;

our $VERSION = '0.01';

use List::Util 'any';
use Scalar::Util 'refaddr';
use Typist::Attribute;
use Typist::Static::CallChecker;
use Typist::Static::Extractor;
use Typist::Static::Infer;
use Typist::Static::NarrowingEngine;
use Typist::Parser;
use Typist::Subtype;
use Typist::Type::Union;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        registry        => $args{registry},
        errors          => $args{errors},
        extracted       => $args{extracted},
        ppi_doc         => $args{ppi_doc},
        file            => $args{file} // '(buffer)',
        narrowing            => Typist::Static::NarrowingEngine->new(
                                    registry => $args{registry},
                                ),
        _loop_var_types      => +{},
        _local_var_types     => +{},
        _inferred_fn_returns => +{},
        _infer_log           => [],
    }, $class;
}

sub loop_var_types       ($self) { $self->{_loop_var_types} }
sub local_var_types      ($self) { $self->{_local_var_types} }
sub callback_param_types ($self) { $self->{_callback_param_types} }
sub narrowed_var_types      ($self) { $self->{narrowing}->narrowed_vars }
sub narrowed_accessor_types ($self) { $self->{narrowing}->narrowed_accessors }
sub inferred_fn_returns     ($self) { $self->{_inferred_fn_returns} }
sub infer_log               ($self) { $self->{_infer_log} }

# ── Public API ───────────────────────────────────

sub analyze ($self) {
    $self->{env} = $self->_build_env;
    $self->{_fn_env_cache} = +{};
    Typist::Static::Infer->clear_callback_params;
    $self->_collect_loop_var_types;
    $self->_collect_local_var_types;
    $self->{narrowing}->collect_accessor_narrowings($self->{ppi_doc});
    $self->_check_variable_initializers;
    $self->_check_assignments;
    Typist::Static::CallChecker->new(
        extracted    => $self->{extracted},
        registry     => $self->{registry},
        errors       => $self->{errors},
        file         => $self->{file},
        ppi_doc      => $self->{ppi_doc},
        env_for_node => sub ($node) { $self->_env_for_node($node) },
        resolve_type => sub ($expr) { $self->_resolve_type($expr) },
        has_type_var => sub ($type) { $self->_has_type_var($type) },
    )->check_call_sites;
    $self->_check_return_types;
    $self->_collect_fn_return_types;
    $self->_collect_match_callback_params;
    $self->{_callback_param_types} = Typist::Static::Infer->callback_params;
}

sub env ($self) { $self->{env} }

# ── Variable Initializer Check ───────────────────

sub _check_variable_initializers ($self) {
    for my $var ($self->{extracted}{variables}->@*) {
        my $init_node = $var->{init_node} // next;

        my $declared = $self->_resolve_type($var->{type_expr});
        next unless defined $declared;
        next if $self->_has_type_var($declared);

        # Use function-scoped env if variable is inside a function body
        my $env = $self->_env_for_node($init_node);
        my $inferred = Typist::Static::Infer->infer_expr($init_node, $env, $declared);
        next unless defined $inferred;
        next if _contains_any($inferred);

        unless (Typist::Subtype->is_subtype($inferred, $declared, registry => $self->{registry})) {
            $self->{errors}->collect(
                kind          => 'TypeMismatch',
                message       => "Variable $var->{name}: expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                file          => $self->{file},
                line          => $var->{line},
                col           => $var->{col} // 0,
                end_col       => ($var->{col} // 0) + length($var->{name}),
                expected_type => $declared->to_string,
                actual_type   => $inferred->to_string,
            );
        }
    }
}

# ── Assignment Check ─────────────────────────────

sub _check_assignments ($self) {
    my $ppi_doc = $self->{ppi_doc} // return;

    # Only check explicitly annotated variables (not inferred ones)
    my %annotated = map { $_->{name} => 1 }
                    grep { $_->{type_expr} }
                    $self->{extracted}{variables}->@*;

    my $ops = $ppi_doc->find('PPI::Token::Operator') || [];
    for my $op (@$ops) {
        next unless $op->content eq '=';

        # LHS: immediate preceding sibling must be a symbol
        my $lhs = $op->sprevious_sibling // next;
        next unless $lhs->isa('PPI::Token::Symbol');

        my $var_name = $lhs->content;
        next unless $annotated{$var_name};

        # Skip variable declarations — _check_variable_initializers handles those
        my $stmt = $op->parent;
        next if $stmt && $stmt->isa('PPI::Statement::Variable');

        # Look up the declared type (already resolved by _build_env)
        my $env = $self->_env_for_node($op);
        my $declared_type = $env->{variables}{$var_name} // next;

        next if $self->_has_type_var($declared_type);

        # Infer the RHS expression type
        my $rhs = $op->snext_sibling // next;
        my $inferred = Typist::Static::Infer->infer_expr($rhs, $env, $declared_type);
        next unless defined $inferred;
        next if _contains_any($inferred);

        unless (Typist::Subtype->is_subtype($inferred, $declared_type, registry => $self->{registry})) {
            $self->{errors}->collect(
                kind          => 'TypeMismatch',
                message       => "Assignment to $var_name: expected ${\$declared_type->to_string}, got ${\$inferred->to_string}",
                file          => $self->{file},
                line          => $lhs->line_number,
                col           => $lhs->column_number,
                end_col       => $lhs->column_number + length($lhs->content),
                expected_type => $declared_type->to_string,
                actual_type   => $inferred->to_string,
            );
        }
    }
}

# ── Return Type Check ───────────────────────────

# Collect inferred return types for unannotated functions (for inlay hints).
sub _collect_fn_return_types ($self) {
    for my $name (sort keys $self->{extracted}{functions}->%*) {
        my $fn = $self->{extracted}{functions}{$name};
        next unless $fn->{unannotated};
        my $block = $fn->{block} // next;

        my $env = $self->_fn_env($fn);
        my @types;

        # Explicit returns
        my $words = $block->find('PPI::Token::Word') || [];
        for my $ret (@$words) {
            next unless $ret->content eq 'return';
            my $val = $ret->snext_sibling // next;
            next if $val->isa('PPI::Token::Structure') && $val->content eq ';';
            my $t = Typist::Static::Infer->infer_expr($val, $self->_env_for_node($ret));
            push @types, $t if $t;
        }

        # Implicit return (last expression)
        my @stmts = $block->schildren;
        if (@stmts) {
            my $last = $stmts[-1];
            my $first = $last->schild(0);
            if ($first && !($first->isa('PPI::Token::Word') && $first->content eq 'return')) {
                # Try statement-level first (ternary/binary), then first-child (match/handle/call)
                my $impl_env = $self->_env_for_node($last);
                my $t = Typist::Static::Infer->infer_expr($last, $impl_env)
                     // Typist::Static::Infer->infer_expr($first, $impl_env);
                push @types, $t if $t;
            }
        }

        next unless @types;
        my $result = $types[0];
        for my $i (1 .. $#types) {
            $result = Typist::Subtype->common_super($result, $types[$i]);
        }
        $result = _widen_literal($result);
        next if $result->is_atom && $result->name eq 'Any';

        $self->{_inferred_fn_returns}{$name} = +{
            type     => $result->to_string,
            line     => $fn->{line},
            name_col => $fn->{name_col},
            name     => $name,
        };
    }
}

sub _check_return_types ($self) {
    for my $name (sort keys $self->{extracted}{functions}->%*) {
        my $fn = $self->{extracted}{functions}{$name};
        my $returns_expr = $fn->{returns_expr} // next;
        my $block = $fn->{block} // next;

        my $declared = $self->_resolve_type($returns_expr);
        next unless defined $declared;

        next if $self->_has_type_var($declared);

        my $env = $self->_fn_env($fn);

        # Find return statements within the block
        my $returns = $block->find('PPI::Token::Word') || [];
        for my $ret (@$returns) {
            next unless $ret->content eq 'return';

            my $val = $ret->snext_sibling // next;
            # skip 'return;' (bare return)
            next if $val->isa('PPI::Token::Structure') && $val->content eq ';';

            # Use node-aware env for narrowing (control flow + early returns)
            my $ret_env = $self->_env_for_node($ret);
            my $inferred = Typist::Static::Infer->infer_expr($val, $ret_env, $declared);
            next unless defined $inferred;
            next if _contains_any($inferred);

            unless (Typist::Subtype->is_subtype($inferred, $declared, registry => $self->{registry})) {
                $self->{errors}->collect(
                    kind          => 'TypeMismatch',
                    message       => "Return value of $name(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                    file          => $self->{file},
                    line          => $val->line_number,
                    col           => $val->column_number,
                    end_col       => $val->column_number + length($val->content),
                    expected_type => $declared->to_string,
                    actual_type   => $inferred->to_string,
                );
            }
        }

        # ── Implicit return (last expression) ──
        # Void return type — implicit value is irrelevant
        next if $declared->is_atom && $declared->name eq 'Void';

        my @children = $block->schildren;
        next unless @children;

        # Use node-aware env for implicit return (accounts for early return narrowing)
        my $last_stmt = $children[-1];
        my $last_first = $last_stmt->schild(0) // $last_stmt;
        my $impl_env = $self->_env_for_node($last_first);
        $self->_check_implicit_return_of_stmt($last_stmt, $impl_env, $declared, $name);
    }
}

# ── Implicit Return: Recursive Branch Walker ───

sub _check_implicit_return_of_stmt ($self, $stmt, $env, $declared, $name) {
    # Skip nested sub definitions
    return if $stmt->isa('PPI::Statement::Sub');

    # Recurse into compound (if/elsif/else/while/for)
    if ($stmt->isa('PPI::Statement::Compound')) {
        my @blocks = grep { $_->isa('PPI::Structure::Block') } $stmt->schildren;
        for my $inner_block (@blocks) {
            my @stmts = grep { $_->isa('PPI::Statement') } $inner_block->schildren;
            next unless @stmts;
            $self->_check_implicit_return_of_stmt($stmts[-1], $env, $declared, $name);
        }
        return;
    }

    # Base case: check expression as implicit return
    my $first = $stmt->schild(0) // return;

    # Skip if starts with 'return' — already checked in explicit path
    return if $first->isa('PPI::Token::Word') && $first->content eq 'return';

    # Try statement-level first (handles mixed-op/ternary), then first-child fallback
    my $inferred = Typist::Static::Infer->infer_expr($stmt, $env, $declared)
                // Typist::Static::Infer->infer_expr($first, $env, $declared);
    return unless defined $inferred;
    return if _contains_any($inferred);

    unless (Typist::Subtype->is_subtype($inferred, $declared, registry => $self->{registry})) {
        $self->{errors}->collect(
            kind          => 'TypeMismatch',
            message       => "Implicit return of $name(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
            file          => $self->{file},
            line          => $first->line_number,
            col           => $first->column_number,
            end_col       => $first->column_number + length($first->content),
            expected_type => $declared->to_string,
            actual_type   => $inferred->to_string,
        );
    }
}

# ── Helpers ──────────────────────────────────────

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

# Build a function-scoped env: base env + parameter bindings.
sub _fn_env ($self, $fn) {
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
            my $bound_type = $self->_resolve_type($g->{bound_expr});
            $bound_map{$g->{name}} = $bound_type if $bound_type;
        }
    }

    # Shallow copy variables hash and add parameter bindings
    my %vars = $base->{variables}->%*;
    for my $i (0 .. $#$names) {
        my $expr = $exprs->[$i] // next;
        my $type = $self->_resolve_type($expr);
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

sub _build_env ($self) {
    my (%variables, %functions, %known);

    # Phase 1: annotated variables + all function return types
    for my $var ($self->{extracted}{variables}->@*) {
        next unless $var->{type_expr};
        my $type = $self->_resolve_type($var->{type_expr});
        $variables{$var->{name}} = $type if $type;
    }

    for my $name (keys $self->{extracted}{functions}->%*) {
        my $fn = $self->{extracted}{functions}{$name};
        $known{$name} = 1 unless $fn->{unannotated};
        if (my $ret_expr = $fn->{returns_expr}) {
            my $type = $self->_resolve_type($ret_expr);
            $functions{$name} = $type if $type;
        }
    }

    # Phase 2: unannotated variables — infer from init expression
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
        my $init_node = $var->{init_node};

        unless ($init_node) {
            push $self->{_infer_log}->@*, +{
                name   => $var->{name}, line => $var->{line},
                type   => undef,        status => 'no_init',
                scope  => 'top',
            };
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
            push $self->{_infer_log}->@*, +{
                name   => $var->{name}, line => $var->{line},
                type   => $widened ? $widened->to_string : undef,
                status => $status,
                scope  => 'top',
            };
            if (defined $inferred && !($inferred->is_atom && $inferred->name eq 'Any')) {
                $variables{$var->{name}} = $widened;
            }
            next;
        }

        my $inferred = Typist::Static::Infer->infer_expr_with_siblings($init_node, $infer_env);

        my $status = !defined $inferred  ? 'undef'
                   : ($inferred->is_atom && $inferred->name eq 'Any') ? 'Any_skip'
                   : 'ok';
        my $widened = ($status eq 'ok') ? _widen_literal($inferred) : $inferred;
        push $self->{_infer_log}->@*, +{
            name   => $var->{name}, line => $var->{line},
            type   => $widened ? $widened->to_string : undef,
            status => $status,
            scope  => 'top',
        };

        next unless defined $inferred;
        next if $inferred->is_atom && $inferred->name eq 'Any';

        $variables{$var->{name}} = $widened;
    }

    $partial_env;
}

# Enrich base env with enclosing function's parameter types.
# Walks up from init_node to find the enclosing PPI::Statement::Sub,
# then adds its declared parameter types to the variables hash.
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
                    my $type = $self->_resolve_type($expr);
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

# Widen literal types for mutable variable bindings.
# Perl's `my` is always mutable, so Literal(v, B) → Atom(B).
# Special case: Bool → Int because 0/1 are numbers in Perl.
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
# Returns an arrayref of types (one per position), or undef entries for unknowns.
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

sub _resolve_type ($self, $expr) {
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

sub _has_type_var ($self, $type) {
    return 1 if $type->is_var;
    return scalar $type->free_vars;
}

# Determine the appropriate env for a PPI node.
# If the node is inside a function body, return fn_env with parameter bindings.
# Additionally, narrow the env based on control flow (e.g. `defined` guards).
sub _env_for_node ($self, $node) {
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
                        $env = $self->_fn_env($fn);
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

# ── Match Callback Collection ────────────────────
#
# Proactively walk standalone match expressions so their callback params
# are collected for LSP hover/inlay hints.  Match expressions inside
# variable initializers or return statements are already covered by the
# existing check methods; this catches the dominant pattern in real code:
#   match $val, Tag => sub ($x) { ... };
#
sub _collect_match_callback_params ($self) {
    my $ppi_doc = $self->{ppi_doc} // return;
    my $words = $ppi_doc->find('PPI::Token::Word') || [];

    my %mgs = (match => 1, map => 1, grep => 1, sort => 1, handle => 1);
    for my $word (@$words) {
        next unless $mgs{$word->content};
        my $env = $self->_env_for_node($word);
        Typist::Static::Infer->infer_expr($word, $env);
    }
}

# ── Local Variable Collection ─────────────────────
#
# Walk each function body in the PPI doc to find unannotated `my $var = EXPR`
# declarations and re-infer them with function-scoped env.  This avoids the
# Extractor's file-level dedup which drops same-name vars in later functions.

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
                my $env = $self->_fn_env($fn);
                $env = $self->_inject_loop_vars($env, $init_node);
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
            my $env = $self->_fn_env($fn);
            $env = $self->_inject_loop_vars($env, $init_node);

            # Inject previously collected local var types so that
            # `my $result = $line` can resolve $line's type.
            if (keys $self->{_local_var_types}->%*) {
                my %vars = $env->{variables}->%*;
                for my $lv (values $self->{_local_var_types}->%*) {
                    next unless $lv->{scope_start} == $fn->{line};
                    $vars{$lv->{name}} //= $lv->{type};
                }
                $env = +{ $env->%*, variables => \%vars };
            }

            my $inferred = Typist::Static::Infer->infer_expr_with_siblings($init_node, $env);

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

#
# Proactively infer loop variable types from extracted loop_variables.
# This ensures _loop_var_types is populated for the symbol index even
# when no type-checking occurs inside loop bodies.

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

# Determine the env for a loop's list node: if the loop is inside a function,
# include parameter bindings so that `for my $x (@$param)` can resolve $param.
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
                        return $self->_fn_env($fn);
                    }
                }
            }
        }
        $ancestor = $ancestor->parent;
    }
    $self->{env};
}

# ── Loop Variable Injection ──────────────────────
#
# Walk ancestors to detect enclosing for/foreach loops. For each loop whose
# Block contains $node, infer the element type and inject the loop variable
# into the env. Outer loops are injected first; inner loops shadow correctly.

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

# Check whether a type transitively contains Any (gradual typing marker).
# Used to skip type checks when inferred types are incomplete.
# Only checks Atom, Func, and Union — NOT Param, because Any inside
# Param (e.g. ArrayRef[Any] from LUB) is a legitimate computed result.
sub _contains_any ($type) {
    return 1 if $type->is_atom && $type->name eq 'Any';
    if ($type->is_func) {
        return 1 if any { _contains_any($_) } $type->params;
        return 1 if _contains_any($type->returns);
    }
    if ($type->is_union) {
        return 1 if any { _contains_any($_) } $type->members;
    }
    # '_' placeholder (unresolved type var) — recurse into Param as well.
    # Unlike Any inside Param (which is a legitimate LUB result), '_' is never
    # produced by LUB and always indicates incomplete inference.
    return 1 if _contains_placeholder($type);
    0;
}

sub _contains_placeholder ($type) {
    return 1 if $type->is_atom && $type->name eq '_';
    if ($type->is_param) {
        return 1 if any { _contains_placeholder($_) } $type->params;
    }
    if ($type->is_func) {
        return 1 if any { _contains_placeholder($_) } $type->params;
        return 1 if _contains_placeholder($type->returns);
    }
    if ($type->is_union) {
        return 1 if any { _contains_placeholder($_) } $type->members;
    }
    0;
}

1;

__END__

=head1 NAME

Typist::Static::TypeChecker - Static type mismatch detection

=head1 DESCRIPTION

PPI-based checker that detects type mismatches at variable initializers,
assignments, call sites, and return statements.  Builds a type environment
from extracted annotations and inferred types, then validates each usage
site against the L<Typist::Subtype> relation.  Supports generic instantiation,
control-flow narrowing, literal widening, and method call resolution.

=head2 new

    my $tc = Typist::Static::TypeChecker->new(
        registry  => $registry,
        errors    => $error_collector,
        extracted => $extracted,
        ppi_doc   => $ppi_doc,
        file      => $filename,
    );

Construct a new TypeChecker for a single compilation unit.  C<$extracted> is
the output of L<Typist::Static::Extractor>, C<$registry> is a
L<Typist::Registry> instance, and C<$errors> is an L<Typist::Error> collector.

=head2 analyze

    $tc->analyze;

Run the full type-checking pipeline: build the type environment, collect
loop and local variable types, check variable initializers, assignments,
call-site arguments, and return types, then harvest callback parameter
bindings from L<Typist::Static::Infer>.

=head2 env

    my $env = $tc->env;

Return the type environment hashref built during C<analyze>.  Maps
variable symbols and function names to their resolved types.

=head2 loop_var_types

    my $vars = $tc->loop_var_types;

Return a hashref mapping C<for>-loop variable names to their inferred
element types (derived from the iterable expression).

=head2 local_var_types

    my $vars = $tc->local_var_types;

Return a hashref mapping unannotated local variable names to their
inferred initializer types (with literal widening applied).

=head2 callback_param_types

    my $params = $tc->callback_param_types;

Return the arrayref of callback parameter type bindings collected
during the most recent C<analyze> pass.

=head2 narrowed_var_types

    my $narrowings = $tc->narrowed_var_types;

Return an arrayref of variable narrowing entries produced by control-flow
analysis (C<defined>, truthiness, C<isa>, C<ref> checks, and early return).

=head2 narrowed_accessor_types

    my $narrowings = $tc->narrowed_accessor_types;

Return an arrayref of accessor narrowing entries produced by control-flow
analysis on method-call receivers.

=head2 inferred_fn_returns

    my $returns = $tc->inferred_fn_returns;

Return a hashref mapping function names to their inferred return types,
collected from the last expression or explicit C<return> in each function body.

=cut
