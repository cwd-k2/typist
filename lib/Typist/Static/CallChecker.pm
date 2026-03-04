package Typist::Static::CallChecker;
use v5.40;

our $VERSION = '0.01';

use List::Util 'any';
use Typist::Attribute;
use Typist::Static::Infer;
use Typist::Static::Unify;
use Typist::Parser;
use Typist::Subtype;
use Typist::Transform;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        extracted     => $args{extracted},
        registry      => $args{registry},
        errors        => $args{errors},
        file          => $args{file},
        ppi_doc       => $args{ppi_doc},
        env_for_node  => $args{env_for_node},
        resolve_type  => $args{resolve_type},
        has_type_var  => $args{has_type_var},
        gradual_hints => $args{gradual_hints},
    }, $class;
}

# ── Delegate Accessors ───────────────────────────

sub _env_for_node ($self, $node) { $self->{env_for_node}->($node) }
sub _resolve_type ($self, $expr) { $self->{resolve_type}->($expr) }
sub _has_type_var ($self, $type) { $self->{has_type_var}->($type) }

# ── Call Site Check ──────────────────────────────

sub check_call_sites ($self) {
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
                ($fn->{line} ? (related => [+{ line => $fn->{line}, col => $fn->{col} // 1, message => "$name() declared here" }]) : ()),
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
                ($fn->{line} ? (related => [+{ line => $fn->{line}, col => $fn->{col} // 1, message => "$name() declared here" }]) : ()),
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
            if (_contains_any($inferred)) {
                $self->_emit_gradual_hint($name, $i, $word, $inferred);
                next;
            }

            unless (Typist::Subtype->is_subtype($inferred, $declared, registry => $self->{registry})) {
                $self->{errors}->collect(
                    kind          => 'TypeMismatch',
                    message       => "Argument " . ($i + 1) . " of $name(): cannot pass ${\$inferred->to_string} as ${\$declared->to_string}",
                    file          => $self->{file},
                    line          => $word->line_number,
                    col           => $word->column_number,
                    end_col       => $word->column_number + length($word->content),
                    expected_type => $declared->to_string,
                    actual_type   => $inferred->to_string,
                    suggestions   => ["Ensure argument is ${\$declared->to_string}"],
                    ($fn->{line} ? (related => [+{ line => $fn->{line}, col => $fn->{col} // 1, message => "$name() declared here" }]) : ()),
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
    my @tp = $struct_type->type_params;

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

    # Pass 1: collect field names, infer value types, collect bindings (generic)
    my %seen;
    my %bindings;
    my @field_checks;   # [{field_name, inferred, expected_type}]
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
                kind        => 'TypeMismatch',
                message     => "${name}(): unknown field '$field_name'",
                file        => $self->{file},
                line        => $word->line_number,
                col         => $word->column_number,
                end_col     => $word->column_number + length($word->content),
                suggestions => ["Available fields: " . join(', ', sort keys %all)],
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

        # Generic: collect bindings from field types
        if (@tp) {
            Typist::Static::Unify->collect_bindings($expected_type, $inferred, \%bindings);
        }

        push @field_checks, +{
            field_name    => $field_name,
            inferred      => $inferred,
            expected_type => $expected_type,
        };
    }

    # Bound / typeclass constraint check on struct generic params
    if ($fn->{generics} && @tp) {
        for my $g ($fn->{generics}->@*) {
            if ($g->{bound_expr}) {
                my $actual = $bindings{$g->{name}} // next;
                my $bound = $self->_resolve_type($g->{bound_expr}) // next;
                unless (Typist::Subtype->is_subtype($actual, $bound, registry => $self->{registry})) {
                    $self->{errors}->collect(
                        kind          => 'TypeMismatch',
                        message       => "${name}(): type ${\$actual->to_string} does not satisfy bound ${\$bound->to_string} for $g->{name}",
                        file          => $self->{file},
                        line          => $word->line_number,
                        col           => $word->column_number,
                        end_col       => $word->column_number + length($word->content),
                        expected_type => $bound->to_string,
                        actual_type   => $actual->to_string,
                    );
                }
            }
            if ($g->{tc_constraints}) {
                my $actual = $bindings{$g->{name}} // next;
                for my $tc_name ($g->{tc_constraints}->@*) {
                    unless ($self->{registry}->resolve_instance($tc_name, $actual)) {
                        $self->{errors}->collect(
                            kind          => 'TypeMismatch',
                            message       => "${name}(): no instance of $tc_name for ${\$actual->to_string}",
                            file          => $self->{file},
                            line          => $word->line_number,
                            col           => $word->column_number,
                            end_col       => $word->column_number + length($word->content),
                            expected_type => $tc_name,
                            actual_type   => $actual->to_string,
                        );
                    }
                }
            }
        }
    }

    # Pass 2: type check fields (with substituted types for generics)
    for my $check (@field_checks) {
        my $expected = $check->{expected_type};
        $expected = Typist::Static::Unify->substitute($expected, \%bindings) if @tp && %bindings;
        # Skip if still contains unresolved type vars
        next if @tp && $self->_has_type_var($expected);
        unless (Typist::Subtype->is_subtype($check->{inferred}, $expected, registry => $self->{registry})) {
            $self->{errors}->collect(
                kind          => 'TypeMismatch',
                message       => "${name}(): field '$check->{field_name}' cannot assign ${\$check->{inferred}->to_string} to ${\$expected->to_string}",
                file          => $self->{file},
                line          => $word->line_number,
                col           => $word->column_number,
                end_col       => $word->column_number + length($word->content),
                expected_type => $expected->to_string,
                actual_type   => $check->{inferred}->to_string,
                suggestions   => ["Change field value to ${\$expected->to_string}"],
            );
        }
    }

    # Missing required fields
    for my $rk (sort keys %$req) {
        next if $seen{$rk};
        $self->{errors}->collect(
            kind        => 'TypeMismatch',
            message     => "${name}(): missing required field '$rk'",
            file        => $self->{file},
            line        => $word->line_number,
            col         => $word->column_number,
            end_col     => $word->column_number + length($word->content),
            suggestions => ["Add field: $rk => ..."],
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
                    message       => "Argument " . ($i + 1) . " of $display(): cannot pass ${\$inferred->to_string} as ${\$declared->to_string}",
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
                        message       => "Argument " . ($i + 1) . " of $display(): cannot pass ${\$inferred->to_string} as ${\$declared->to_string}",
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
            message       => "Argument " . ($failed_at + 1) . " of $name(): cannot pass ${\$arg_types[$failed_at]->to_string} as ${\$param_types[$failed_at]->to_string}",
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

    # 5.5 Typeclass constraint check (static)
    for my $g (@generics) {
        next unless $g->{tc_constraints};
        my $actual = $bindings->{$g->{name}} // next;
        for my $tc_name ($g->{tc_constraints}->@*) {
            my $inst = $self->{registry}->resolve_instance($tc_name, $actual);
            unless ($inst) {
                $self->{errors}->collect(
                    kind          => 'TypeMismatch',
                    message       => "Argument of $name(): no instance of $tc_name for ${\$actual->to_string}",
                    file          => $self->{file},
                    line          => $word->line_number,
                    col           => $word->column_number,
                    end_col       => $word->column_number + length($word->content),
                    expected_type => $tc_name,
                    actual_type   => $actual->to_string,
                );
            }
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
                message       => "Argument " . ($i + 1) . " of $name(): cannot pass ${\$arg_types[$i]->to_string} as ${\$concrete->to_string}",
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
# Each entry is like "T", "T: Num", "r: Row", or already-structured hashrefs.
# Delegates to Attribute->parse_generic_decl when registry is available,
# so that typeclass constraints (T: Show) are properly distinguished from
# bounded quantification (T: Num).
sub _parse_generics ($self, $generics_raw) {
    my @result;
    my @raw_strings;
    for my $g ($generics_raw->@*) {
        # Already structured (from registry): { name => ..., bound_expr => ... }
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

# ── PPI Argument Helpers ─────────────────────────

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

# ── GradualHint Emission ────────────────────────

sub _emit_gradual_hint ($self, $name, $arg_idx, $word, $inferred) {
    return unless $self->{gradual_hints};
    my $n = $arg_idx + 1;
    $self->{errors}->collect(
        kind    => 'GradualHint',
        message => "Argument $n of $name() not checked: inferred type contains Any (${\$inferred->to_string})",
        file    => $self->{file},
        line    => $word->line_number,
        col     => $word->column_number,
        end_col => $word->column_number + length($word->content),
    );
}

# ── Type Utility Functions ───────────────────────

# Check whether a type transitively contains Any (gradual typing marker).
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

=head1 NAME

Typist::Static::CallChecker - Call site type checking for function and method calls

=head1 SYNOPSIS

    use Typist::Static::CallChecker;

    my $checker = Typist::Static::CallChecker->new(
        extracted    => $extracted,
        registry     => $registry,
        errors       => $errors,
        file         => $file,
        ppi_doc      => $ppi_doc,
        env_for_node => sub ($node) { ... },
        resolve_type => sub ($expr) { ... },
        has_type_var => sub ($type) { ... },
    );
    $checker->check_call_sites;

=head1 DESCRIPTION

Encapsulates call-site type checking logic: function calls, method calls,
struct constructors, generic instantiation, chained methods, and PPI
argument extraction. Extracted from TypeChecker to reduce module size
and isolate call-checking responsibility.

=head1 SEE ALSO

L<Typist::Static::TypeChecker>, L<Typist::Static::NarrowingEngine>

=cut
