package Typist::Static::TypeChecker;
use v5.40;

our $VERSION = '0.01';

use List::Util 'any';
use Scalar::Util 'refaddr';
use Typist::Static::Extractor;
use Typist::Static::Infer;
use Typist::Static::Unify;
use Typist::Parser;
use Typist::Subtype;
use Typist::Transform;
use Typist::Type::Union;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        registry        => $args{registry},
        errors          => $args{errors},
        extracted       => $args{extracted},
        ppi_doc         => $args{ppi_doc},
        file            => $args{file} // '(buffer)',
        _loop_var_types      => +{},
        _local_var_types     => +{},
        _narrowed_vars       => [],
        _narrowed_accessors  => [],
        _inferred_fn_returns => +{},
    }, $class;
}

sub loop_var_types       ($self) { $self->{_loop_var_types} }
sub local_var_types      ($self) { $self->{_local_var_types} }
sub callback_param_types ($self) { $self->{_callback_param_types} }
sub narrowed_var_types      ($self) { $self->{_narrowed_vars} }
sub narrowed_accessor_types ($self) { $self->{_narrowed_accessors} }
sub inferred_fn_returns     ($self) { $self->{_inferred_fn_returns} }

# ── Public API ───────────────────────────────────

sub analyze ($self) {
    $self->{env} = $self->_build_env;
    $self->{_fn_env_cache} = +{};
    Typist::Static::Infer->clear_callback_params;
    $self->_collect_loop_var_types;
    $self->_collect_local_var_types;
    $self->_collect_accessor_narrowings;
    $self->_check_variable_initializers;
    $self->_check_assignments;
    $self->_check_call_sites;
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
                            params_expr        => [map { $_->to_string } ($sig->{params} // [])->@*],
                            generics           => $sig->{generics},
                            variadic           => $sig->{variadic},
                            default_count      => $sig->{default_count} // 0,
                            struct_constructor => $sig->{struct_constructor},
                            returns            => $sig->{returns},
                        };
                    }
                }
            }

            # Fallback: builtin (CORE::name) from prelude or declare
            unless ($cross_pkg) {
                my $core_sig = $self->{registry}->lookup_function('CORE', $name);
                if ($core_sig) {
                    $cross_pkg = +{
                        params_expr        => $core_sig->{params_expr}
                            // [map { $_->to_string } ($core_sig->{params} // [])->@*],
                        generics           => $core_sig->{generics},
                        variadic           => $core_sig->{variadic},
                        default_count      => $core_sig->{default_count} // 0,
                        struct_constructor => $core_sig->{struct_constructor},
                        returns            => $core_sig->{returns},
                    };
                }
            }

            # Current-package function (e.g., ADT constructor registered by Analyzer)
            unless ($cross_pkg) {
                my $pkg = $self->{extracted}{package} // 'main';
                my $pkg_sig = $self->{registry}->lookup_function($pkg, $name);
                if ($pkg_sig) {
                    $cross_pkg = +{
                        params_expr        => $pkg_sig->{params_expr}
                            // [map { $_->to_string } ($pkg_sig->{params} // [])->@*],
                        generics           => $pkg_sig->{generics},
                        variadic           => $pkg_sig->{variadic},
                        default_count      => $pkg_sig->{default_count} // 0,
                        struct_constructor => $pkg_sig->{struct_constructor},
                        returns            => $pkg_sig->{returns},
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
        next unless ref($next) && $next->isa('PPI::Structure::List');

        # Struct constructor: named-arg check instead of positional
        if ($fn->{struct_constructor} && $fn->{returns} && $fn->{returns}->is_struct) {
            $self->_check_struct_constructor_call($name, $fn, $next, $self->_env_for_node($word), $word);
            next;
        }

        my @param_exprs = $fn->{params_expr}->@*;

        # Determine the env: use function-scoped env if call is inside a function body
        my $env = $self->_env_for_node($word);

        # Extract argument expressions from the list
        my @args = $self->_extract_args($next);

        # ── Arity check ──────────────────────────────
        my $is_variadic = $fn->{variadic};
        my $default_count = $fn->{default_count} // 0;
        my $min_args = $is_variadic ? @param_exprs - 1 : @param_exprs - $default_count;

        if (@args < $min_args) {
            my $expect = $is_variadic ? "at least $min_args" : "${\scalar @param_exprs}";
            $self->{errors}->collect(
                kind    => 'ArityMismatch',
                message => "$name() expects $expect arguments, got ${\scalar @args}",
                file    => $self->{file},
                line    => $word->line_number,
                col     => $word->column_number,
                end_col => $word->column_number + length($word->content),
            );
            next;
        }

        if (@args > @param_exprs && !$is_variadic) {
            $self->{errors}->collect(
                kind    => 'ArityMismatch',
                message => "$name() expects ${\scalar @param_exprs} arguments, got ${\scalar @args}",
                file    => $self->{file},
                line    => $word->line_number,
                col     => $word->column_number,
                end_col => $word->column_number + length($word->content),
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
            my $declared = $self->_resolve_type($param_exprs[$i]);
            next unless defined $declared;
            next if $self->_has_type_var($declared);

            # Callback arity check: anonymous sub vs Func parameter
            if ($declared->is_func && $self->_is_anon_sub($args[$i])) {
                my $expected_arity = scalar($declared->params);
                my $actual_arity   = $self->_count_anon_sub_params($args[$i]);
                if (defined $actual_arity
                    && $actual_arity != $expected_arity
                    && !$declared->variadic)
                {
                    $self->{errors}->collect(
                        kind    => 'ArityMismatch',
                        message => "Callback argument " . ($i + 1)
                            . " of $name(): expected $expected_arity parameter(s), got $actual_arity",
                        file    => $self->{file},
                        line    => $word->line_number,
                        col     => $word->column_number,
                        end_col => $word->column_number + length($word->content),
                    );
                    next;
                }
            }

            my $inferred = Typist::Static::Infer->infer_expr($args[$i], $env, $declared);
            next unless defined $inferred;
            next if _contains_any($inferred);

            unless (Typist::Subtype->is_subtype($inferred, $declared, registry => $self->{registry})) {
                $self->{errors}->collect(
                    kind          => 'TypeMismatch',
                    message       => "Argument " . ($i + 1) . " of $name(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                    file          => $self->{file},
                    line          => $word->line_number,
                    col           => $word->column_number,
                    end_col       => $word->column_number + length($word->content),
                    expected_type => $declared->to_string,
                    actual_type   => $inferred->to_string,
                );
            }
        }
    }
}

# ── Struct Constructor Check ─────────────────────

# Check named-argument calls to struct constructors:
#   Person(name => "Alice", age => 30)
# Validates field names, types, and required-field completeness.
sub _check_struct_constructor_call ($self, $name, $fn, $list, $env, $word) {
    my $struct_type = $fn->{returns};
    my $req = $struct_type->required_ref // +{};
    my $opt = $struct_type->optional_ref // +{};
    my %all = (%$req, %$opt);

    # Extract key => value pairs from the PPI List
    my $expr = $list->find_first('PPI::Statement::Expression')
            // $list->find_first('PPI::Statement');
    return unless $expr;

    # Split children into comma-separated groups
    my @groups;
    my @current;
    for my $child ($expr->schildren) {
        if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
            push @groups, [@current] if @current;
            @current = ();
        } else {
            push @current, $child;
        }
    }
    push @groups, [@current] if @current;

    my %seen;
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

        # Extract field name
        my $key_tok = $group->[0];
        my $field_name;
        if ($key_tok->isa('PPI::Token::Word')) {
            $field_name = $key_tok->content;
        } elsif ($key_tok->isa('PPI::Token::Quote')) {
            $field_name = $key_tok->string;
        }
        next unless defined $field_name;

        $seen{$field_name} = 1;

        # Unknown field check
        unless (exists $all{$field_name}) {
            $self->{errors}->collect(
                kind    => 'TypeMismatch',
                message => "${name}(): unknown field '$field_name'",
                file    => $self->{file},
                line    => $word->line_number,
                col     => $word->column_number,
                end_col => $word->column_number + length($word->content),
            );
            next;
        }

        # Infer value type
        my $val_token = $group->[$arrow_idx + 1];
        next unless $val_token;

        my $expected_type = $all{$field_name};
        my $inferred = Typist::Static::Infer->infer_expr($val_token, $env, $expected_type);
        next unless defined $inferred;
        next if _contains_any($inferred);

        unless (Typist::Subtype->is_subtype($inferred, $expected_type, registry => $self->{registry})) {
            $self->{errors}->collect(
                kind          => 'TypeMismatch',
                message       => "${name}(): field '$field_name' expected ${\$expected_type->to_string}, got ${\$inferred->to_string}",
                file          => $self->{file},
                line          => $word->line_number,
                col           => $word->column_number,
                end_col       => $word->column_number + length($word->content),
                expected_type => $expected_type->to_string,
                actual_type   => $inferred->to_string,
            );
        }
    }

    # Missing required fields
    for my $rk (sort keys %$req) {
        next if $seen{$rk};
        $self->{errors}->collect(
            kind    => 'TypeMismatch',
            message => "${name}(): missing required field '$rk'",
            file    => $self->{file},
            line    => $word->line_number,
            col     => $word->column_number,
            end_col => $word->column_number + length($word->content),
        );
    }
}

# ── Method Call Check ────────────────────────────

# Check a method call: $receiver->method(args)
# Path A: $self → current package lookup
# Path B: any receiver → env-based type resolution → package lookup
sub _check_method_call ($self, $word, $arrow) {
    my $name = $word->content;

    my $receiver = $arrow->sprevious_sibling // return;

    my $env = $self->_env_for_node($word);
    my ($pkg, $display, $recv_type);

    if ($receiver->isa('PPI::Token::Symbol')) {
        if ($receiver->content eq '$self') {
            # Path A: same-package instance method
            $pkg     = $self->{extracted}{package};
            $display = "\$self->${name}";
        } else {
            # Path B: resolve receiver type from env
            $recv_type = $env->{variables}{$receiver->content} // return;

            # Chase aliases to reach the concrete type
            if ($recv_type->is_alias) {
                my $resolved = $self->{registry}->lookup_type($recv_type->alias_name);
                $recv_type = $resolved if $resolved;
            }

            # Must be a struct (nominal) type to look up methods
            if ($recv_type->is_struct) {
                $pkg = $recv_type->name;
            } elsif ($recv_type->is_record) {
                # Record: handled below in type checking
                $pkg = undef;
            } else {
                return;  # unknown / non-struct → gradual skip
            }
            $display = $receiver->content . "->${name}";
        }
    } elsif ($receiver->isa('PPI::Token::Word')) {
        # Path C: Class->method() — bareword class name
        my $class_name = $receiver->content;
        my $resolved = $self->{registry}->lookup_type($class_name);
        if ($resolved && $resolved->is_struct) {
            $pkg = $class_name;
        } else {
            return;  # unknown class → gradual skip
        }
        $display = "${class_name}->${name}";
    } else {
        return;
    }

    # Record receiver: look up field as accessor
    if (!$pkg && $recv_type && $recv_type->is_record) {
        return $self->_check_record_method($word, $name, $recv_type, $display);
    }

    return unless $pkg;

    # Look up method: try source package first, then struct blessed package
    my $method_sig = $self->{registry}->lookup_method($pkg, $name);
    unless ($method_sig) {
        # Struct accessor methods are under the blessed package (Typist::Struct::Name)
        if ($recv_type && $recv_type->is_struct) {
            $method_sig = $self->{registry}->lookup_method($recv_type->package, $name);
        } elsif ($receiver->isa('PPI::Token::Word')) {
            # Class method: try the blessed package pattern
            my $struct_type = $self->{registry}->lookup_type($pkg);
            if ($struct_type && $struct_type->is_struct) {
                $method_sig = $self->{registry}->lookup_method($struct_type->package, $name);
            }
        }
    }
    return unless $method_sig;

    # The argument list must follow the method name
    my $arg_list = $word->snext_sibling // return;
    return unless ref $arg_list && $arg_list->isa('PPI::Structure::List');

    # Generic methods: delegate to _check_generic_call with pseudo-fn
    if ($method_sig->{generics} && $method_sig->{generics}->@*) {
        my @args = $self->_extract_args($arg_list);
        my $pseudo_fn = +{
            params_expr => [map { $_->to_string } ($method_sig->{params} // [])->@*],
            generics    => $method_sig->{generics},
            variadic    => $method_sig->{variadic},
        };
        $self->_check_generic_call($display, $pseudo_fn, \@args, $env, $word);
        return;
    }

    my @param_types = ($method_sig->{params} // [])->@*;
    my @param_exprs = map { $_->to_string } @param_types;

    my @args = $self->_extract_args($arg_list);

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
            col     => $word->column_number,
            end_col => $word->column_number + length($word->content),
        );
        return if @args < $min_args;
    }

    # ── Type check each argument ─────────────────
    if (@param_exprs) {
        my $n = @param_exprs < @args ? @param_exprs : @args;
        for my $i (0 .. $n - 1) {
            my $declared = $self->_resolve_type($param_exprs[$i]);
            next unless defined $declared;
            next if $self->_has_type_var($declared);

            my $inferred = Typist::Static::Infer->infer_expr($args[$i], $env, $declared);
            next unless defined $inferred;
            next if _contains_any($inferred);

            unless (Typist::Subtype->is_subtype($inferred, $declared, registry => $self->{registry})) {
                $self->{errors}->collect(
                    kind          => 'TypeMismatch',
                    message       => "Argument " . ($i + 1) . " of $display(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                    file          => $self->{file},
                    line          => $word->line_number,
                    col           => $word->column_number,
                    end_col       => $word->column_number + length($word->content),
                    expected_type => $declared->to_string,
                    actual_type   => $inferred->to_string,
                );
            }
        }
    }

    # ── Chain detection ──────────────────────────
    # If the arg list is followed by '->' Word, check the chain
    my $chain_arrow = $arg_list->snext_sibling;
    if ($chain_arrow && ref $chain_arrow
        && $chain_arrow->isa('PPI::Token::Operator') && $chain_arrow->content eq '->')
    {
        my $return_type = $method_sig->{returns};
        if ($return_type) {
            $self->_check_chained_method($return_type, $chain_arrow, $env);
        }
    }
}

# Check chained method calls: $obj->m1()->m2()->m3()
# Resolves return type to struct, looks up next method, and recurses.
sub _check_chained_method ($self, $return_type, $arrow, $env) {
    my $method_word = $arrow->snext_sibling // return;
    return unless ref $method_word && $method_word->isa('PPI::Token::Word');
    my $name = $method_word->content;

    # Resolve return type to struct
    my $resolved = $return_type;
    if ($resolved->is_alias) {
        my $looked = $self->{registry}->lookup_type($resolved->alias_name);
        $resolved = $looked if $looked;
    }
    return unless $resolved->is_struct;  # non-struct return → gradual skip

    my $pkg = $resolved->name;
    my $display = "..." . "->${name}";

    # Look up method
    my $method_sig = $self->{registry}->lookup_method($pkg, $name);
    unless ($method_sig) {
        $method_sig = $self->{registry}->lookup_method($resolved->package, $name);
    }
    return unless $method_sig;

    my $arg_list = $method_word->snext_sibling // return;
    return unless ref $arg_list && $arg_list->isa('PPI::Structure::List');

    # Generic methods: delegate
    if ($method_sig->{generics} && $method_sig->{generics}->@*) {
        my @args = $self->_extract_args($arg_list);
        my $pseudo_fn = +{
            params_expr => [map { $_->to_string } ($method_sig->{params} // [])->@*],
            generics    => $method_sig->{generics},
            variadic    => $method_sig->{variadic},
        };
        $self->_check_generic_call($display, $pseudo_fn, \@args, $env, $method_word);
    } else {
        my @param_types = ($method_sig->{params} // [])->@*;
        my @param_exprs = map { $_->to_string } @param_types;
        my @args = $self->_extract_args($arg_list);

        # Arity check
        my $is_variadic = $method_sig->{variadic};
        my $min_args = $is_variadic ? @param_exprs - 1 : @param_exprs;
        if (@args < $min_args || (!$is_variadic && @args > @param_exprs)) {
            my $expect = $is_variadic ? "at least $min_args" : "${\scalar @param_exprs}";
            $self->{errors}->collect(
                kind    => 'ArityMismatch',
                message => "$display() expects $expect arguments, got ${\scalar @args}",
                file    => $self->{file},
                line    => $method_word->line_number,
                col     => $method_word->column_number,
                end_col => $method_word->column_number + length($method_word->content),
            );
        }

        # Type check each argument
        if (@param_exprs) {
            my $n = @param_exprs < @args ? @param_exprs : @args;
            for my $i (0 .. $n - 1) {
                my $declared = $self->_resolve_type($param_exprs[$i]);
                next unless defined $declared;
                next if $self->_has_type_var($declared);
                my $inferred = Typist::Static::Infer->infer_expr($args[$i], $env, $declared);
                next unless defined $inferred;
                next if _contains_any($inferred);
                unless (Typist::Subtype->is_subtype($inferred, $declared, registry => $self->{registry})) {
                    $self->{errors}->collect(
                        kind          => 'TypeMismatch',
                        message       => "Argument " . ($i + 1) . " of $display(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                        file          => $self->{file},
                        line          => $method_word->line_number,
                        col           => $method_word->column_number,
                        end_col       => $method_word->column_number + length($method_word->content),
                        expected_type => $declared->to_string,
                        actual_type   => $inferred->to_string,
                    );
                }
            }
        }
    }

    # Continue the chain recursively
    my $next_arrow = $arg_list->snext_sibling;
    if ($next_arrow && ref $next_arrow
        && $next_arrow->isa('PPI::Token::Operator') && $next_arrow->content eq '->')
    {
        my $next_return = $method_sig->{returns};
        if ($next_return) {
            $self->_check_chained_method($next_return, $next_arrow, $env);
        }
    }
}

# Record accessor method check: Record field as zero-arg accessor.
sub _check_record_method ($self, $word, $name, $recv_type, $display) {
    # Look up field in Record's required/optional fields
    my $field_type;
    my %req = $recv_type->required_ref ? $recv_type->required_ref->%* : ();
    my %opt = $recv_type->optional_ref ? $recv_type->optional_ref->%* : ();
    $field_type = $req{$name} // $opt{$name};
    return unless $field_type;  # unknown field → gradual skip

    # Accessor should be called with zero args
    my $arg_list = $word->snext_sibling // return;
    return unless ref $arg_list && $arg_list->isa('PPI::Structure::List');

    my @args = $self->_extract_args($arg_list);
    if (@args > 0) {
        $self->{errors}->collect(
            kind    => 'ArityMismatch',
            message => "$display() is an accessor, expects 0 arguments, got ${\scalar @args}",
            file    => $self->{file},
            line    => $word->line_number,
            col     => $word->column_number,
            end_col => $word->column_number + length($word->content),
        );
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
                my $t = Typist::Static::Infer->infer_expr($last, $env)
                     // Typist::Static::Infer->infer_expr($first, $env);
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

    my $inferred = Typist::Static::Infer->infer_expr($first, $env, $declared);
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

# ── Generic Call Check ──────────────────────────

sub _check_generic_call ($self, $name, $fn, $args, $env, $word) {
    # 1. Infer argument types (gradual: skip if any arg is non-inferable)
    my @arg_types;
    for my $arg (@$args) {
        my $inferred = Typist::Static::Infer->infer_expr($arg, $env);
        return unless defined $inferred;
        return if _contains_any($inferred);
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
        $bindings = Typist::Static::Unify->unify($param_types[$i], $arg_types[$i], $bindings, registry => $self->{registry});
        unless ($bindings) {
            $failed_at = $i;
            last;
        }
    }

    # Unification failure → structural mismatch at the failing parameter
    unless ($bindings) {
        $self->{errors}->collect(
            kind          => 'TypeMismatch',
            message       => "Argument " . ($failed_at + 1) . " of $name(): expected ${\$param_types[$failed_at]->to_string}, got ${\$arg_types[$failed_at]->to_string}",
            file          => $self->{file},
            line          => $word->line_number,
            col           => $word->column_number,
            end_col       => $word->column_number + length($word->content),
            expected_type => $param_types[$failed_at]->to_string,
            actual_type   => $arg_types[$failed_at]->to_string,
        );
        return;
    }

    # 5. Bounded quantification check
    for my $g (@generics) {
        next unless $g->{bound_expr};
        my $actual = $bindings->{$g->{name}} // next;
        my $bound = $self->_resolve_type($g->{bound_expr}) // next;
        unless (Typist::Subtype->is_subtype($actual, $bound, registry => $self->{registry})) {
            $self->{errors}->collect(
                kind          => 'TypeMismatch',
                message       => "Argument of $name(): ${\$actual->to_string} does not satisfy bound ${\$bound->to_string} for type variable $g->{name}",
                file          => $self->{file},
                line          => $word->line_number,
                col           => $word->column_number,
                end_col       => $word->column_number + length($word->content),
                expected_type => $bound->to_string,
                actual_type   => $actual->to_string,
            );
        }
    }

    # 6. Concrete subtype check: substitute bindings and verify each arg
    for my $i (0 .. $n - 1) {
        my $concrete = Typist::Static::Unify->substitute($param_types[$i], $bindings);
        next if $self->_has_type_var($concrete);
        next if _contains_any($arg_types[$i]);
        unless (Typist::Subtype->is_subtype($arg_types[$i], $concrete, registry => $self->{registry})) {
            $self->{errors}->collect(
                kind          => 'TypeMismatch',
                message       => "Argument " . ($i + 1) . " of $name(): expected ${\$concrete->to_string}, got ${\$arg_types[$i]->to_string}",
                file          => $self->{file},
                line          => $word->line_number,
                col           => $word->column_number,
                end_col       => $word->column_number + length($word->content),
                expected_type => $concrete->to_string,
                actual_type   => $arg_types[$i]->to_string,
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

        # Enrich env with enclosing function parameters for accurate inference
        my $infer_env = $self->_scoped_env($partial_env, $init_node);
        my $inferred = Typist::Static::Infer->infer_expr_with_siblings($init_node, $infer_env);
        next unless defined $inferred;
        next if $inferred->is_atom && $inferred->name eq 'Any';

        $variables{$var->{name}} = _widen_literal($inferred);
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
    $env = $self->_narrow_env_for_block($env, $node);
    $env = $self->_scan_early_returns($env, $node);
    $env;
}

# ── Accessor Narrowing Collection ────────────────
#
# Proactively scan for `if (defined($var->field))` patterns and record
# the narrowed accessor scope for LSP hover.  This runs independently of
# type checking because bare accessor expressions inside then-blocks are
# not visited by _narrow_env_for_block.
sub _collect_accessor_narrowings ($self) {
    my $ppi_doc = $self->{ppi_doc} // return;
    my $compounds = $ppi_doc->find('PPI::Statement::Compound') || [];

    for my $compound (@$compounds) {
        my ($keyword) = grep { $_->isa('PPI::Token::Word') } $compound->schildren;
        next unless $keyword;
        my $kw = $keyword->content;
        next unless $kw eq 'if' || $kw eq 'unless';

        my ($condition) = grep { $_->isa('PPI::Structure::Condition') } $compound->schildren;
        next unless $condition;

        my @cond_children = $condition->schildren;
        my $expr = $cond_children[0];
        if ($expr && $expr->isa('PPI::Statement::Expression')) {
            @cond_children = $expr->schildren;
        }

        my $accessor = $self->_extract_defined_accessor(\@cond_children);
        next unless $accessor;

        my $is_unless = $kw eq 'unless';
        my @blocks = grep { $_->isa('PPI::Structure::Block') } $compound->schildren;

        for my $i (0 .. $#blocks) {
            my $apply = $is_unless ? ($i > 0) : ($i == 0);
            next unless $apply;

            my $block       = $blocks[$i];
            my $block_start = $block->line_number;
            my $block_last  = $block->last_element;
            my $block_end   = $block_last ? $block_last->line_number : $block_start;

            push $self->{_narrowed_accessors}->@*, +{
                var_name    => $accessor->{var_name},
                chain       => $accessor->{chain},
                scope_start => $block_start,
                scope_end   => $block_end,
            };
        }
    }
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

            # Find $var = EXPR pattern
            my ($var_name, $var_sym, $init_node);
            for my $i (0 .. $#children) {
                if ($children[$i]->isa('PPI::Token::Symbol') && !$var_name) {
                    $var_name = $children[$i]->content;
                    $var_sym  = $children[$i];
                }
                if ($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq '=') {
                    $init_node = $children[$i + 1] if $i + 1 <= $#children;
                    last;
                }
            }
            next unless $var_name && $init_node;

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
            next unless defined $inferred;
            next if $inferred->is_atom && $inferred->name eq 'Any';

            my $key = $var_name . ':' . $var_sym->line_number;
            $self->{_local_var_types}{$key} = +{
                name        => $var_name,
                type        => _widen_literal($inferred),
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

# ── Narrowing Rules ──────────────────────────────

# Remove Undef from a Union type, returning the narrowed type or undef if no change.
sub _remove_undef_from_type ($self, $type) {
    return undef unless $type && $type->is_union;

    my @non_undef = grep {
        !($_->is_atom && $_->name eq 'Undef')
    } $type->members;

    # Nothing removed — no narrowing needed
    return undef if @non_undef == scalar($type->members);

    @non_undef == 1
        ? $non_undef[0]
        : Typist::Type::Union->new(@non_undef);
}

# Extract a Symbol node from a `defined(...)` or `defined $x` pattern.
sub _extract_defined_symbol ($self, $cond_children) {
    return undef unless @$cond_children >= 2;
    return undef unless $cond_children->[0]->isa('PPI::Token::Word')
                     && $cond_children->[0]->content eq 'defined';

    my $list = $cond_children->[1];

    if ($list->isa('PPI::Structure::List')) {
        my @list_children = grep { $_->isa('PPI::Statement::Expression') } $list->schildren;
        if (@list_children) {
            my @exprs = $list_children[0]->schildren;
            return $exprs[0] if @exprs && $exprs[0]->isa('PPI::Token::Symbol');
        }
    } elsif ($list->isa('PPI::Token::Symbol')) {
        return $list;
    }

    undef;
}

# Extract accessor chain from `defined($var->field)` or `defined $var->field`.
# Returns { var_name => '$x', chain => ['field'] } or undef.
sub _extract_defined_accessor ($self, $cond_children) {
    return undef unless @$cond_children >= 2;
    return undef unless $cond_children->[0]->isa('PPI::Token::Word')
                     && $cond_children->[0]->content eq 'defined';

    # Collect the tokens after 'defined' — either inside parens or bare
    my @tokens;
    my $second = $cond_children->[1];

    if ($second->isa('PPI::Structure::List')) {
        my @exprs = grep { $_->isa('PPI::Statement::Expression') } $second->schildren;
        @tokens = $exprs[0]->schildren if @exprs;
    } else {
        @tokens = @$cond_children[1 .. $#$cond_children];
    }

    # Expect: Symbol, Operator(->), Word [, Operator(->), Word ...]
    return undef unless @tokens >= 3;
    return undef unless $tokens[0]->isa('PPI::Token::Symbol');

    my $var_name = $tokens[0]->content;
    my @chain;

    my $i = 1;
    while ($i + 1 <= $#tokens) {
        last unless $tokens[$i]->isa('PPI::Token::Operator')
                 && $tokens[$i]->content eq '->';
        last unless $tokens[$i + 1]->isa('PPI::Token::Word');
        push @chain, $tokens[$i + 1]->content;
        $i += 2;
    }

    return undef unless @chain;
    +{ var_name => $var_name, chain => \@chain };
}

# Rule: `defined($x)` narrows T | Undef to T.
# Returns { var_name => narrowed_type } or empty hash.
sub _narrow_defined ($self, $cond_children, $env) {
    my $var_symbol = $self->_extract_defined_symbol($cond_children) // return +{};
    my $var_name = $var_symbol->content;
    my $var_type = $env->{variables}{$var_name};
    my $narrowed = $self->_remove_undef_from_type($var_type) // return +{};
    +{ $var_name => $narrowed };
}

# Rule: bare variable truthiness `if ($x)` narrows T | Undef to T.
# Returns { var_name => narrowed_type } or empty hash.
sub _narrow_truthiness ($self, $cond_children, $env) {
    # Exactly one child that is a Symbol
    return +{} unless @$cond_children == 1;
    return +{} unless $cond_children->[0]->isa('PPI::Token::Symbol');

    my $var_name = $cond_children->[0]->content;
    my $var_type = $env->{variables}{$var_name};
    my $narrowed = $self->_remove_undef_from_type($var_type) // return +{};
    +{ $var_name => $narrowed };
}

# Shared ref() type map and resolution logic.
# Returns { var_name => type } or empty hash.
my %REF_MAP = (
    HASH    => 'HashRef[Any]',
    ARRAY   => 'ArrayRef[Any]',
    SCALAR  => 'Ref[Any]',
    CODE    => 'Ref[Any]',
    REF     => 'Ref[Any]',
    Regexp  => 'Ref[Any]',
    GLOB    => 'Ref[Any]',
    IO      => 'Ref[Any]',
    VSTRING => 'Str',
);

sub _narrow_ref_resolve ($self, $var_name, $op_str, $ref_string) {
    my %result;

    my $type_expr;
    if (exists $REF_MAP{$ref_string}) {
        $type_expr = $REF_MAP{$ref_string};
    } else {
        # Blessed object: try to resolve as struct/type name
        my $resolved = $self->_resolve_type($ref_string);
        return +{} unless $resolved;
        $type_expr = undef;
        %result = ($var_name => $resolved);
    }

    unless (%result) {
        my $narrowed = $self->_resolve_type($type_expr) // return +{};
        %result = ($var_name => $narrowed);
    }

    # Attach operator metadata for ne handling
    $result{_ref_op} = $op_str if $op_str ne 'eq';

    +{%result};
}

# Rule: `ref($x) eq 'TYPE'` or `ref $x eq 'TYPE'` narrows $x.
# Maps: HASH → HashRef[Any], ARRAY → ArrayRef[Any], SCALAR → Ref[Any], etc.
# Blessed class names are resolved via registry.
sub _narrow_ref ($self, $cond_children, $env) {
    return +{} unless @$cond_children >= 3;

    my $ref_word = $cond_children->[0];
    return +{} unless $ref_word->isa('PPI::Token::Word') && $ref_word->content eq 'ref';

    my ($var_name, $op_idx);

    # Path A: ref($x) — Word('ref') List(Symbol) ...
    if ($cond_children->[1]->isa('PPI::Structure::List')) {
        my $list = $cond_children->[1];
        my @inner = $list->schildren;
        my $expr = $inner[0];
        @inner = $expr->schildren if $expr && $expr->isa('PPI::Statement::Expression');
        return +{} unless @inner == 1 && $inner[0]->isa('PPI::Token::Symbol');
        $var_name = $inner[0]->content;
        $op_idx = 2;
    }
    # Path B: ref $x — Word('ref') Symbol('$x') ...
    elsif ($cond_children->[1]->isa('PPI::Token::Symbol')) {
        $var_name = $cond_children->[1]->content;
        $op_idx = 2;
    }
    else {
        return +{};
    }

    return +{} unless @$cond_children > $op_idx + 1;

    my $op = $cond_children->[$op_idx];
    return +{} unless $op->isa('PPI::Token::Operator') && ($op->content eq 'eq' || $op->content eq 'ne');
    my $op_str = $op->content;

    my $quote_node = $cond_children->[$op_idx + 1];

    # The RHS can be a Quote literal or a variable
    my $ref_string;
    if ($quote_node->isa('PPI::Token::Quote')) {
        $ref_string = $quote_node->string;
    } elsif ($quote_node->isa('PPI::Token::Symbol')) {
        # Variable comparison: resolve from env to Literal string
        my $var_type = $env->{variables}{$quote_node->content};
        if ($var_type && $var_type->is_literal && $var_type->base_type eq 'Str') {
            $ref_string = $var_type->value;
        } else {
            return +{};  # Unknown variable value → gradual skip
        }
    } else {
        return +{};
    }

    $self->_narrow_ref_resolve($var_name, $op_str, $ref_string);
}

# Rule: `$x isa Type` narrows $x to Type.
# Returns { var_name => narrowed_type } or empty hash.
sub _narrow_isa ($self, $cond_children, $env) {
    return +{} unless @$cond_children >= 3;
    return +{} unless $cond_children->[0]->isa('PPI::Token::Symbol');

    my $isa_token = $cond_children->[1];
    return +{} unless ($isa_token->isa('PPI::Token::Operator') || $isa_token->isa('PPI::Token::Word'))
                    && $isa_token->content eq 'isa';

    my $type_token = $cond_children->[2];
    return +{} unless $type_token->isa('PPI::Token::Word');

    my $var_name  = $cond_children->[0]->content;
    my $type_name = $type_token->content;
    my $resolved  = $self->_resolve_type($type_name) // return +{};

    +{ $var_name => $resolved };
}

# Compute inverse narrowing for else-blocks.
# For `defined`: variable is Undef.
# For `ref`/`isa` with Union: subtract narrowed type from Union members.
# For truthiness: no useful inverse, return empty.
sub _inverse_narrowing ($self, $rule, $var_name, $original_type) {
    if ($rule eq 'defined') {
        return +{ $var_name => Typist::Type::Atom->new('Undef') };
    }

    # ref/isa inverse: subtract narrowed type from Union
    if (($rule eq 'ref' || $rule eq 'isa') && $original_type && $original_type->is_union) {
        my $narrowed = $self->{_last_narrowed_type}{$var_name};
        if ($narrowed) {
            my @remaining = grep {
                !$narrowed->equals($_)
                && !Typist::Subtype->is_subtype($_, $narrowed, registry => $self->{registry})
            } $original_type->members;

            if (@remaining == 1) {
                return +{ $var_name => $remaining[0] };
            } elsif (@remaining > 1) {
                return +{ $var_name => Typist::Type::Union->new(@remaining) };
            }
        }
    }

    +{};
}

# Narrow the env based on control flow guards surrounding $node.
# Dispatches through narrowing rules and supports both then- and else-blocks.
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

    # Determine which block we are in: then (index 0) or else (index 1+)
    my @blocks = grep { $_->isa('PPI::Structure::Block') } $compound->schildren;
    return $env unless @blocks;

    my $block_index = -1;
    for my $i (0 .. $#blocks) {
        if ($blocks[$i] == $block) {
            $block_index = $i;
            last;
        }
    }
    return $env if $block_index < 0;

    # Extract the condition
    my ($condition) = grep { $_->isa('PPI::Structure::Condition') } $compound->schildren;
    return $env unless $condition;

    # Unwrap: Condition -> Expression -> children
    my @cond_children = $condition->schildren;
    my $expr = $cond_children[0];
    if ($expr && $expr->isa('PPI::Statement::Expression')) {
        @cond_children = $expr->schildren;
    }

    # Dispatch through narrowing rules (order matters: most specific first)
    my %narrowing;
    my $rule;

    my %try_defined = $self->_narrow_defined(\@cond_children, $env)->%*;
    if (%try_defined) {
        %narrowing = %try_defined;
        $rule = 'defined';
    }

    unless ($rule) {
        my %try_isa = $self->_narrow_isa(\@cond_children, $env)->%*;
        if (%try_isa) {
            %narrowing = %try_isa;
            $rule = 'isa';
        }
    }

    unless ($rule) {
        my %try_ref = $self->_narrow_ref(\@cond_children, $env)->%*;
        if (%try_ref) {
            %narrowing = %try_ref;
            $rule = 'ref';
        }
    }

    unless ($rule) {
        my %try_truth = $self->_narrow_truthiness(\@cond_children, $env)->%*;
        if (%try_truth) {
            %narrowing = %try_truth;
            $rule = 'truthiness';
        }
    }

    return $env unless $rule;

    # Detect `unless` keyword — reverses narrowing polarity
    my ($keyword) = grep { $_->isa('PPI::Token::Word') } $compound->schildren;
    my $is_unless = $keyword && $keyword->content eq 'unless';

    # For `if`:     block 0 = then (direct), block 1+ = else (inverse)
    # For `unless`: block 0 = body (inverse), block 1+ = else (direct)
    my $apply_direct = $is_unless ? ($block_index > 0) : ($block_index == 0);

    # `ne` operator in ref() flips the polarity
    if ($rule eq 'ref' && ($narrowing{_ref_op} // '') eq 'ne') {
        $apply_direct = !$apply_direct;
    }
    delete $narrowing{_ref_op};

    # Save narrowed types for inverse narrowing (ref/isa with Union)
    for my $var_name (keys %narrowing) {
        $self->{_last_narrowed_type}{$var_name} = $narrowing{$var_name};
    }

    # Compute the narrowed variable set based on polarity
    my %applied;
    if ($apply_direct) {
        %applied = %narrowing;
    } else {
        for my $var_name (keys %narrowing) {
            my $original = $env->{variables}{$var_name};
            my %inv = $self->_inverse_narrowing($rule, $var_name, $original)->%*;
            $applied{$_} = $inv{$_} for keys %inv;
        }
    }

    return $env unless %applied;

    # Record narrowed variables for LSP visibility
    my $block_start = $block->line_number;
    my $block_last  = $block->last_element;
    my $block_end   = $block_last ? $block_last->line_number : $block_start;
    for my $var_name (keys %applied) {
        push $self->{_narrowed_vars}->@*, +{
            name        => $var_name,
            type        => $applied{$var_name},
            scope_start => $block_start,
            scope_end   => $block_end,
        };
    }

    my %new_vars = $env->{variables}->%*;
    $new_vars{$_} = $applied{$_} for keys %applied;
    +{ %$env, variables => \%new_vars };
}

# ── Early Return Narrowing ──────────────────────

# Scan for `return ... unless defined $var` patterns before the current node's
# containing statement. Each such pattern narrows the env by removing Undef.
sub _scan_early_returns ($self, $env, $node) {
    # Find the statement containing this node
    my $stmt = $node;
    while ($stmt && !$stmt->isa('PPI::Statement')) {
        $stmt = $stmt->parent;
    }
    return $env unless $stmt;

    # The statement must live inside a Block
    my $parent_block = $stmt->parent;
    return $env unless $parent_block && $parent_block->isa('PPI::Structure::Block');

    # Walk preceding sibling statements
    my %narrowed_vars;
    my $sib = $stmt->sprevious_sibling;
    while ($sib) {
        if ($sib->isa('PPI::Statement')) {
            my @children = $sib->schildren;
            # Match: return [expr] unless defined $var
            if ($self->_is_early_return_unless_defined(\@children)) {
                my $var_name = $self->_early_return_var(\@children);
                if ($var_name) {
                    my $var_type = $env->{variables}{$var_name};
                    my $narrowed = $self->_remove_undef_from_type($var_type);
                    $narrowed_vars{$var_name} = $narrowed if $narrowed;
                }
            }
        }
        $sib = $sib->sprevious_sibling;
    }

    return $env unless %narrowed_vars;

    # Record narrowed variables for LSP visibility
    my $fn_block = $parent_block;
    my $fn_last  = $fn_block->last_element;
    my $scope_start = $stmt->line_number;
    my $scope_end   = $fn_last ? $fn_last->line_number : $scope_start;
    for my $var_name (keys %narrowed_vars) {
        push $self->{_narrowed_vars}->@*, +{
            name        => $var_name,
            type        => $narrowed_vars{$var_name},
            scope_start => $scope_start,
            scope_end   => $scope_end,
        };
    }

    my %new_vars = $env->{variables}->%*;
    $new_vars{$_} = $narrowed_vars{$_} for keys %narrowed_vars;
    +{ %$env, variables => \%new_vars };
}

# Check if statement children match: return [exprs] unless defined $var [;]
sub _is_early_return_unless_defined ($self, $children) {
    return 0 unless @$children >= 4;
    return 0 unless $children->[0]->isa('PPI::Token::Word')
                  && $children->[0]->content eq 'return';

    # Find 'unless' token — it can be at various positions depending on
    # whether there is a return value expression
    for my $i (1 .. $#$children - 2) {
        if ($children->[$i]->isa('PPI::Token::Word')
            && $children->[$i]->content eq 'unless'
            && $children->[$i + 1]->isa('PPI::Token::Word')
            && $children->[$i + 1]->content eq 'defined')
        {
            return 1;
        }
    }
    0;
}

# Extract the variable name from a `return ... unless defined $var` statement.
sub _early_return_var ($self, $children) {
    for my $i (1 .. $#$children - 2) {
        if ($children->[$i]->isa('PPI::Token::Word')
            && $children->[$i]->content eq 'unless'
            && $children->[$i + 1]->isa('PPI::Token::Word')
            && $children->[$i + 1]->content eq 'defined')
        {
            # The variable follows `defined` — either directly or inside a list
            my $next = $children->[$i + 2];
            if ($next->isa('PPI::Token::Symbol')) {
                return $next->content;
            }
            if ($next->isa('PPI::Structure::List')) {
                my @lc = grep { $_->isa('PPI::Statement::Expression') } $next->schildren;
                if (@lc) {
                    my @exprs = $lc[0]->schildren;
                    return $exprs[0]->content
                        if @exprs && $exprs[0]->isa('PPI::Token::Symbol');
                }
            }
        }
    }
    undef;
}

# Check if a PPI element represents an anonymous sub (Word 'sub' not in Statement::Sub)
sub _is_anon_sub ($self, $element) {
    return 0 unless $element->isa('PPI::Token::Word') && $element->content eq 'sub';
    my $parent = $element->parent;
    return 0 if $parent && $parent->isa('PPI::Statement::Sub');
    1;
}

# Count parameters of an anonymous sub from its PPI element (the 'sub' Word)
sub _count_anon_sub_params ($self, $element) {
    my $next = $element->snext_sibling;
    # PPI parses anonymous sub signatures as Prototype tokens
    if ($next && $next->isa('PPI::Token::Prototype')) {
        my $content = $next->content;
        my $count = 0;
        $count++ while $content =~ /[\$\@%]\w/g;
        return $count;
    }
    if ($next && $next->isa('PPI::Structure::List')) {
        my $expr = $next->schild(0);
        return 0 unless $expr;
        my $count = 0;
        for my $tok ($expr->schildren) {
            $count++ if $tok->isa('PPI::Token::Symbol') && $tok->content =~ /\A[\$\@%]/;
        }
        return $count;
    }
    # No signature — zero params
    0;
}

sub _extract_args ($self, $list) {
    # Use direct child — not recursive find — to avoid matching nested Statements
    # inside anonymous sub signatures, constructors, etc.
    my $expr = $list->schild(0);
    return () unless $expr && $expr->isa('PPI::Statement');

    # Group compound expressions as single arguments:
    #   sub [+ sig] + Block → anonymous sub  (e.g. sub ($x) { ... })
    #   Word + List         → function call   (e.g. greet("hi"))
    #   Token + -> + Sub   → dereference chain (e.g. $item->{key}, $arr->[0])
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

        # Anonymous sub: sub [prototype/signature] { body }
        if ($child->isa('PPI::Token::Word') && $child->content eq 'sub') {
            push @args, $child;
            $i++;

            # Skip optional signature (List) or prototype (Prototype)
            if ($i < @children
                && ($children[$i]->isa('PPI::Structure::List')
                    || $children[$i]->isa('PPI::Token::Prototype')))
            {
                $i++;
            }

            # Skip block body
            if ($i < @children && $children[$i]->isa('PPI::Structure::Block')) {
                $i++;
            }
        }
        # Word followed by List → function call (count as one arg)
        elsif ($i + 1 < @children
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

        # Consume remaining infix expression parts (e.g., $n + 1, $a . $b)
        # Everything between commas belongs to the same argument
        while ($i < @children
            && !($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq ','))
        {
            $i++;
        }
    }

    @args;
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
