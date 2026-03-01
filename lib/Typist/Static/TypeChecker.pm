package Typist::Static::TypeChecker;
use v5.40;

use Typist::Static::Infer;
use Typist::Static::Unify;
use Typist::Parser;
use Typist::Subtype;
use Typist::Transform;
use Typist::Type::Union;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        registry  => $args{registry},
        errors    => $args{errors},
        extracted => $args{extracted},
        ppi_doc   => $args{ppi_doc},
        file      => $args{file} // '(buffer)',
    }, $class;
}

# ── Public API ───────────────────────────────────

sub analyze ($self) {
    $self->{env} = $self->_build_env;
    $self->_check_variable_initializers;
    $self->_check_assignments;
    $self->_check_call_sites;
    $self->_check_return_types;
}

sub env ($self) { $self->{env} }

# ── Variable Initializer Check ───────────────────

sub _check_variable_initializers ($self) {
    for my $var ($self->{extracted}{variables}->@*) {
        my $init_node = $var->{init_node} // next;

        my $inferred = Typist::Static::Infer->infer_expr($init_node, $self->{env});
        next unless defined $inferred;
        next if $inferred->is_atom && $inferred->name eq 'Any';

        my $declared = $self->_resolve_type($var->{type_expr});
        next unless defined $declared;

        next if $self->_has_type_var($declared);

        unless (Typist::Subtype->is_subtype($inferred, $declared)) {
            $self->{errors}->collect(
                kind    => 'TypeMismatch',
                message => "Variable $var->{name}: expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                file    => $self->{file},
                line    => $var->{line},
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
        my $inferred = Typist::Static::Infer->infer_expr($rhs, $env);
        next unless defined $inferred;
        next if $inferred->is_atom && $inferred->name eq 'Any';

        unless (Typist::Subtype->is_subtype($inferred, $declared_type)) {
            $self->{errors}->collect(
                kind    => 'TypeMismatch',
                message => "Assignment to $var_name: expected ${\$declared_type->to_string}, got ${\$inferred->to_string}",
                file    => $self->{file},
                line    => $op->line_number,
            );
        }
    }
}

# ── Call Site Check ──────────────────────────────

sub _check_call_sites ($self) {
    my $ppi_doc = $self->{ppi_doc} // return;
    my $words = $ppi_doc->find('PPI::Token::Word') || [];

    for my $word (@$words) {
        my $name = $word->content;

        # Method call: ->name
        my $prev = $word->sprevious_sibling;
        if ($prev && ref $prev && $prev->isa('PPI::Token::Operator') && $prev->content eq '->') {
            $self->_check_method_call($word, $prev);
            next;
        }

        # Try local extraction first, then registry for cross-package calls (Pkg::func),
        # then CORE:: fallback for builtin functions.
        my $fn = $self->{extracted}{functions}{$name};
        my $cross_pkg;
        unless ($fn) {
            # Check for Pkg::func pattern via registry
            if ($name =~ /::/) {
                my ($pkg, $fname) = $name =~ /\A(.+)::(\w+)\z/;
                if ($pkg && $fname) {
                    my $sig = $self->{registry}->lookup_function($pkg, $fname);
                    if ($sig) {
                        $cross_pkg = +{
                            params_expr => [map { $_->to_string } ($sig->{params} // [])->@*],
                            generics    => $sig->{generics},
                        };
                    }
                }
            }

            # Fallback: builtin (CORE::name) from prelude or declare
            unless ($cross_pkg) {
                my $core_sig = $self->{registry}->lookup_function('CORE', $name);
                if ($core_sig) {
                    $cross_pkg = +{
                        params_expr => $core_sig->{params_expr}
                            // [map { $_->to_string } ($core_sig->{params} // [])->@*],
                        generics    => $core_sig->{generics},
                    };
                }
            }

            # Current-package function (e.g., ADT constructor registered by Analyzer)
            unless ($cross_pkg) {
                my $pkg = $self->{extracted}{package} // 'main';
                my $pkg_sig = $self->{registry}->lookup_function($pkg, $name);
                if ($pkg_sig) {
                    $cross_pkg = +{
                        params_expr => $pkg_sig->{params_expr}
                            // [map { $_->to_string } ($pkg_sig->{params} // [])->@*],
                        generics    => $pkg_sig->{generics},
                    };
                }
            }

            next unless $cross_pkg;
            $fn = $cross_pkg;
        }

        # Skip if the word is part of a sub declaration
        my $parent = $word->parent;
        next if $parent && $parent->isa('PPI::Statement::Sub');

        # Find the argument list — next sibling should be a List
        my $next = $word->snext_sibling // next;
        next unless $next->isa('PPI::Structure::List');

        my @param_exprs = $fn->{params_expr}->@*;

        # Determine the env: use function-scoped env if call is inside a function body
        my $env = $self->_env_for_node($word);

        # Extract argument expressions from the list
        my @args = $self->_extract_args($next);

        # ── Arity check ──────────────────────────────
        my $is_variadic = $fn->{variadic};
        my $min_args = $is_variadic ? @param_exprs - 1 : @param_exprs;

        if (@args < $min_args) {
            my $expect = $is_variadic ? "at least $min_args" : "${\scalar @param_exprs}";
            $self->{errors}->collect(
                kind    => 'ArityMismatch',
                message => "$name() expects $expect arguments, got ${\scalar @args}",
                file    => $self->{file},
                line    => $word->line_number,
            );
            next;
        }

        if (@args > @param_exprs && !$is_variadic) {
            $self->{errors}->collect(
                kind    => 'ArityMismatch',
                message => "$name() expects ${\scalar @param_exprs} arguments, got ${\scalar @args}",
                file    => $self->{file},
                line    => $word->line_number,
            );
        }

        next unless @param_exprs;

        # ── Generic function: instantiate via unification ──
        if ($fn->{generics} && $fn->{generics}->@*) {
            $self->_check_generic_call($name, $fn, \@args, $env, $word);
            next;
        }

        my $n = @param_exprs < @args ? @param_exprs : @args;
        for my $i (0 .. $n - 1) {
            my $inferred = Typist::Static::Infer->infer_expr($args[$i], $env);
            next unless defined $inferred;
            next if $inferred->is_atom && $inferred->name eq 'Any';

            my $declared = $self->_resolve_type($param_exprs[$i]);
            next unless defined $declared;

            next if $self->_has_type_var($declared);

            unless (Typist::Subtype->is_subtype($inferred, $declared)) {
                $self->{errors}->collect(
                    kind    => 'TypeMismatch',
                    message => "Argument " . ($i + 1) . " of $name(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                    file    => $self->{file},
                    line    => $word->line_number,
                );
            }
        }
    }
}

# ── Method Call Check ────────────────────────────

# Check a single method call: $self->method(args)
# Phase 2: only $self receivers within the same package.
sub _check_method_call ($self, $word, $arrow) {
    my $name = $word->content;

    # Only handle $self->method() pattern (same-package instance methods)
    my $receiver = $arrow->sprevious_sibling // return;
    return unless $receiver->isa('PPI::Token::Symbol') && $receiver->content eq '$self';

    # Look up the method in the current package's registry
    my $pkg = $self->{extracted}{package};
    my $method_sig = $self->{registry}->lookup_method($pkg, $name);
    return unless $method_sig;

    # Skip generic methods (type variables can't be resolved statically)
    return if $method_sig->{generics} && $method_sig->{generics}->@*;

    # The argument list must follow the method name
    my $arg_list = $word->snext_sibling // return;
    return unless $arg_list->isa('PPI::Structure::List');

    my @param_types = ($method_sig->{params} // [])->@*;
    my @param_exprs = map { $_->to_string } @param_types;

    my $env = $self->_env_for_node($word);
    my @args = $self->_extract_args($arg_list);
    my $display = "\$self->${name}";

    # ── Arity check ──────────────────────────────
    my $is_variadic = $method_sig->{variadic};
    my $min_args = $is_variadic ? @param_exprs - 1 : @param_exprs;

    if (@args < $min_args || (!$is_variadic && @args > @param_exprs)) {
        my $expect = $is_variadic ? "at least $min_args" : "${\scalar @param_exprs}";
        $self->{errors}->collect(
            kind    => 'ArityMismatch',
            message => "$display() expects $expect arguments, got ${\scalar @args}",
            file    => $self->{file},
            line    => $word->line_number,
        );
        return if @args < $min_args;
    }

    return unless @param_exprs;

    # ── Type check each argument ─────────────────
    my $n = @param_exprs < @args ? @param_exprs : @args;
    for my $i (0 .. $n - 1) {
        my $inferred = Typist::Static::Infer->infer_expr($args[$i], $env);
        next unless defined $inferred;
        next if $inferred->is_atom && $inferred->name eq 'Any';

        my $declared = $self->_resolve_type($param_exprs[$i]);
        next unless defined $declared;
        next if $self->_has_type_var($declared);

        unless (Typist::Subtype->is_subtype($inferred, $declared)) {
            $self->{errors}->collect(
                kind    => 'TypeMismatch',
                message => "Argument " . ($i + 1) . " of $display(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                file    => $self->{file},
                line    => $word->line_number,
            );
        }
    }
}

# ── Return Type Check ───────────────────────────

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

            my $inferred = Typist::Static::Infer->infer_expr($val, $env);
            next unless defined $inferred;
            next if $inferred->is_atom && $inferred->name eq 'Any';

            unless (Typist::Subtype->is_subtype($inferred, $declared)) {
                $self->{errors}->collect(
                    kind    => 'TypeMismatch',
                    message => "Return value of $name(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                    file    => $self->{file},
                    line    => $ret->line_number,
                );
            }
        }

        # ── Implicit return (last expression) ──
        # Void return type — implicit value is irrelevant
        next if $declared->is_atom && $declared->name eq 'Void';

        my @children = $block->schildren;
        next unless @children;

        my $last_stmt = $children[-1];
        $self->_check_implicit_return_of_stmt($last_stmt, $env, $declared, $name);
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

    my $inferred = Typist::Static::Infer->infer_expr($first, $env);
    return unless defined $inferred;
    return if $inferred->is_atom && $inferred->name eq 'Any';

    unless (Typist::Subtype->is_subtype($inferred, $declared)) {
        $self->{errors}->collect(
            kind    => 'TypeMismatch',
            message => "Implicit return of $name(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
            file    => $self->{file},
            line    => $first->line_number,
        );
    }
}

# ── Generic Call Check ──────────────────────────

sub _check_generic_call ($self, $name, $fn, $args, $env, $word) {
    # 1. Infer argument types (gradual: skip if any arg is non-inferable)
    my @arg_types;
    for my $arg (@$args) {
        my $inferred = Typist::Static::Infer->infer_expr($arg, $env);
        return unless defined $inferred;
        return if $inferred->is_atom && $inferred->name eq 'Any';
        push @arg_types, $inferred;
    }

    # 2. Parse generic declarations to extract var names and bounds
    my @generics = $self->_parse_generics($fn->{generics});
    my %var_names = map { $_->{name} => 1 } @generics;

    # 3. Resolve formal parameter types, converting aliases to type variables
    my @param_types;
    for my $expr ($fn->{params_expr}->@*) {
        my $t = $self->_resolve_type($expr) // return;
        $t = Typist::Transform->aliases_to_vars($t, \%var_names);
        push @param_types, $t;
    }

    # 4. Unify: pair formal params with actual args to bind type variables
    my $bindings = +{};
    my $n = @param_types < @arg_types ? @param_types : @arg_types;
    my $failed_at = -1;
    for my $i (0 .. $n - 1) {
        $bindings = Typist::Static::Unify->unify($param_types[$i], $arg_types[$i], $bindings);
        unless ($bindings) {
            $failed_at = $i;
            last;
        }
    }

    # Unification failure → structural mismatch at the failing parameter
    unless ($bindings) {
        $self->{errors}->collect(
            kind    => 'TypeMismatch',
            message => "Argument " . ($failed_at + 1) . " of $name(): expected ${\$param_types[$failed_at]->to_string}, got ${\$arg_types[$failed_at]->to_string}",
            file    => $self->{file},
            line    => $word->line_number,
        );
        return;
    }

    # 5. Bounded quantification check
    for my $g (@generics) {
        next unless $g->{bound_expr};
        my $actual = $bindings->{$g->{name}} // next;
        my $bound = $self->_resolve_type($g->{bound_expr}) // next;
        unless (Typist::Subtype->is_subtype($actual, $bound)) {
            $self->{errors}->collect(
                kind    => 'TypeMismatch',
                message => "Argument of $name(): ${\$actual->to_string} does not satisfy bound ${\$bound->to_string} for type variable $g->{name}",
                file    => $self->{file},
                line    => $word->line_number,
            );
        }
    }

    # 6. Concrete subtype check: substitute bindings and verify each arg
    for my $i (0 .. $n - 1) {
        my $concrete = Typist::Static::Unify->substitute($param_types[$i], $bindings);
        next if $self->_has_type_var($concrete);
        next if $arg_types[$i]->is_atom && $arg_types[$i]->name eq 'Any';
        unless (Typist::Subtype->is_subtype($arg_types[$i], $concrete)) {
            $self->{errors}->collect(
                kind    => 'TypeMismatch',
                message => "Argument " . ($i + 1) . " of $name(): expected ${\$concrete->to_string}, got ${\$arg_types[$i]->to_string}",
                file    => $self->{file},
                line    => $word->line_number,
            );
        }
    }
}

# Parse generics_raw strings into structured declarations.
# Each entry is like "T", "T: Num", "r: Row".
sub _parse_generics ($self, $generics_raw) {
    my @result;
    for my $g ($generics_raw->@*) {
        # Already structured (from registry): { name => ..., bound_expr => ... }
        if (ref $g eq 'HASH' && exists $g->{name}) {
            push @result, $g;
            next;
        }
        my $trimmed = $g;
        $trimmed =~ s/\A\s+//;
        $trimmed =~ s/\s+\z//;
        if ($trimmed =~ /\A(\w+)\s*:\s*(.+)\z/) {
            push @result, +{ name => $1, bound_expr => $2 };
        } else {
            push @result, +{ name => $trimmed, bound_expr => undef };
        }
    }
    @result;
}

# ── Helpers ──────────────────────────────────────

# Build a function-scoped env: base env + parameter bindings.
sub _fn_env ($self, $fn) {
    my $base = $self->{env};
    my $names  = $fn->{param_names}  // [];
    my $exprs  = $fn->{params_expr}  // [];

    return $base unless @$names;

    # Shallow copy variables hash and add parameter bindings
    my %vars = $base->{variables}->%*;
    for my $i (0 .. $#$names) {
        my $expr = $exprs->[$i] // next;
        my $type = $self->_resolve_type($expr) // next;
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
        my $init_node = $var->{init_node} // next;

        my $inferred = Typist::Static::Infer->infer_expr($init_node, $partial_env);
        next unless defined $inferred;
        next if $inferred->is_atom && $inferred->name eq 'Any';

        $variables{$var->{name}} = $inferred;
    }

    $partial_env;
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
            # Check if this block belongs to a known function
            my $sub_stmt = $ancestor->parent;
            if ($sub_stmt && $sub_stmt->isa('PPI::Statement::Sub')) {
                my $fn_name = $sub_stmt->name;
                if ($fn_name && $self->{extracted}{functions}{$fn_name}) {
                    my $fn = $self->{extracted}{functions}{$fn_name};
                    if ($fn->{block} && $fn->{block} == $ancestor) {
                        $env = $self->_fn_env($fn);
                        last;
                    }
                }
            }
        }
        $ancestor = $ancestor->parent;
    }
    $env //= $self->{env};

    $self->_narrow_env_for_block($env, $node);
}

# Narrow the env based on control flow guards surrounding $node.
# Phase B-2a: `defined($var)` in an if-condition removes Undef from
# the variable's Union type within the then-block.
sub _narrow_env_for_block ($self, $env, $node) {
    # Walk up to the nearest enclosing Block
    my $block = $node;
    while ($block && !$block->isa('PPI::Structure::Block')) {
        $block = $block->parent;
    }
    return $env unless $block;

    # The block's parent must be a Compound statement (if/elsif/unless/while)
    my $compound = $block->parent;
    return $env unless $compound && $compound->isa('PPI::Statement::Compound');

    # Only narrow inside the first (then) block of the compound — not else
    my @blocks = grep { $_->isa('PPI::Structure::Block') } $compound->schildren;
    return $env unless @blocks && $blocks[0] == $block;

    # Extract the condition
    my ($condition) = grep { $_->isa('PPI::Structure::Condition') } $compound->schildren;
    return $env unless $condition;

    # Unwrap: Condition → Expression → children
    my @cond_children = $condition->schildren;
    my $expr = $cond_children[0];
    if ($expr && $expr->isa('PPI::Statement::Expression')) {
        @cond_children = $expr->schildren;
    }

    # Match `defined($x)` or `defined $x`
    return $env unless @cond_children >= 2;
    return $env unless $cond_children[0]->isa('PPI::Token::Word')
                    && $cond_children[0]->content eq 'defined';

    my $var_symbol;
    my $list = $cond_children[1];

    if ($list->isa('PPI::Structure::List')) {
        # defined($x) — Symbol inside List > Expression
        my @list_children = grep { $_->isa('PPI::Statement::Expression') } $list->schildren;
        if (@list_children) {
            my @exprs = $list_children[0]->schildren;
            $var_symbol = $exprs[0] if @exprs && $exprs[0]->isa('PPI::Token::Symbol');
        }
    } elsif ($list->isa('PPI::Token::Symbol')) {
        # defined $x — space-separated form
        $var_symbol = $list;
    }

    return $env unless $var_symbol;

    my $var_name = $var_symbol->content;
    my $var_type = $env->{variables}{$var_name};

    # Only narrow Union types that contain Undef
    return $env unless $var_type && $var_type->is_union;

    my @non_undef = grep {
        !($_->is_atom && $_->name eq 'Undef')
    } $var_type->members;

    # If nothing was removed, no narrowing needed
    return $env if @non_undef == scalar($var_type->members);

    my $narrowed = @non_undef == 1
        ? $non_undef[0]
        : Typist::Type::Union->new(@non_undef);

    my %new_vars = $env->{variables}->%*;
    $new_vars{$var_name} = $narrowed;

    +{ %$env, variables => \%new_vars };
}

sub _extract_args ($self, $list) {
    # List contains an Expression with comma-separated args
    my $expr = $list->find_first('PPI::Statement::Expression')
            // $list->find_first('PPI::Statement');
    return () unless $expr;

    # Group compound expressions as single arguments:
    #   Word + List       → function call   (e.g. greet("hi"))
    #   Token + -> + Sub  → dereference chain (e.g. $item->{key}, $arr->[0])
    my @children = $expr->schildren;
    my @args;
    my $i = 0;
    while ($i < @children) {
        my $child = $children[$i];

        # Skip commas
        if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
            $i++;
            next;
        }

        # Word followed by List → function call (count as one arg)
        if ($i + 1 < @children
            && $child->isa('PPI::Token::Word')
            && $children[$i + 1]->isa('PPI::Structure::List'))
        {
            push @args, $child;
            $i += 2;    # skip the List
        }
        else {
            push @args, $child;
            $i++;
        }

        # Consume trailing dereference chain: -> followed by Subscript/List
        while ($i + 1 < @children
            && $children[$i]->isa('PPI::Token::Operator')
            && $children[$i]->content eq '->'
            && ($children[$i + 1]->isa('PPI::Structure::Subscript')
                || $children[$i + 1]->isa('PPI::Structure::List')))
        {
            $i += 2;    # skip -> and the subscript/list
        }
    }

    @args;
}

1;
