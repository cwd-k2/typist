package Typist::Static::TypeChecker;
use v5.40;

our $VERSION = '0.01';

use List::Util 'any';
use Typist::Static::CallChecker;
use Typist::Static::Infer;
use Typist::Static::Timing;
use Typist::Static::TypeEnv;
use Typist::Subtype;
use Typist::Type::Atom;
use Typist::Type::Param;
use Scalar::Util 'refaddr';

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        type_env             => $args{type_env},
        # Backward compat: old-style construction without TypeEnv
        registry             => $args{registry},
        ppi_doc              => $args{ppi_doc},
        # Always needed
        errors               => $args{errors},
        extracted            => $args{extracted},
        file                 => $args{file} // '(buffer)',
        gradual_hints        => $args{gradual_hints},
        _inferred_fn_returns => +{},
        _infer_expr_cache    => +{},
        _has_type_var_cache  => +{},
        timings              => $args{timings},
    }, $class;
}

# ── Delegating Accessors ────────────────────────

sub env                     ($self) { $self->{type_env}->env }
sub loop_var_types          ($self) { $self->{type_env}->loop_var_types }
sub local_var_types         ($self) { $self->{type_env}->local_var_types }
sub infer_log               ($self) { $self->{type_env}->infer_log }
sub narrowed_var_types      ($self) { $self->{type_env}->narrowed_var_types }
sub narrowed_accessor_types ($self) { $self->{type_env}->narrowed_accessor_types }

# ── Own Accessors ───────────────────────────────

sub callback_param_types ($self) { $self->{_callback_param_types} }
sub inferred_fn_returns  ($self) { $self->{_inferred_fn_returns} }

# ── Public API ──────────────────────────────────

# Backward-compatible full pipeline (builds TypeEnv if not provided).
sub analyze ($self) {
    unless ($self->{type_env}) {
        $self->{type_env} = Typist::Static::TypeEnv->new(
            registry  => $self->{registry},
            extracted => $self->{extracted},
            ppi_doc   => $self->{ppi_doc},
        );
        $self->{type_env}->build;
    }
    local $Typist::Static::Infer::_CALLBACK_CTX = { params => [], seen => {} };
    $self->check_variables;
    $self->check_assignments;
    $self->check_call_sites;
    $self->check_match_exhaustiveness;
    for my $name (sort keys $self->{extracted}{functions}->%*) {
        $self->check_function_returns($name);
    }
    $self->collect_fn_return_types;
    $self->collect_callback_params;
}

# ── Phase 4: File-Level Checks ──────────────────

sub check_variables :TIMED(variables) ($self) {
    for my $var ($self->{extracted}{variables}->@*) {
        my $init_node = $var->{init_node} // next;

        my $declared = $self->_resolve_type($var->{type_expr});
        next unless defined $declared;
        next if $self->_has_type_var_cached($declared);

        # Use function-scoped env if variable is inside a function body
        my $env = $self->_env_for_node($init_node);
        my $inferred = Typist::Static::Infer->infer_expr($init_node, $env, $declared);
        next unless defined $inferred;
        next if _contains_any($inferred);

        unless (Typist::Subtype->is_subtype($inferred, $declared, registry => $self->{type_env}->registry)) {
            $self->{errors}->collect(
                kind          => 'TypeMismatch',
                message       => "Variable $var->{name}: cannot assign ${\$inferred->to_string} to ${\$declared->to_string}",
                file          => $self->{file},
                line          => $var->{line},
                col           => $var->{col} // 0,
                end_col       => ($var->{col} // 0) + length($var->{name}),
                expected_type => $declared->to_string,
                actual_type   => $inferred->to_string,
                explanation   => [
                    "Declared type: ${\$declared->to_string}",
                    "Inferred initializer type: ${\$inferred->to_string}",
                    "Initializer is not a subtype of the declared annotation",
                ],
                suggestions   => ["Change annotation to :sig(${\$inferred->to_string})"],
                related       => [+{ line => $var->{line}, col => $var->{col} // 1, message => 'declared here' }],
            );
        }
    }
}

sub check_assignments :TIMED(assignments) ($self) {

    # Only check explicitly annotated variables (not inferred ones)
    my %annotated = map { $_->{name} => 1 }
                    grep { $_->{type_expr} }
                    $self->{extracted}{variables}->@*;

    my %var_info = map { $_->{name} => $_ }
                   grep { $_->{type_expr} }
                   $self->{extracted}{variables}->@*;

    my $ops = $self->{extracted}{assignment_ops} // [];
    for my $op (@$ops) {
        # LHS: immediate preceding sibling must be a symbol
        my $lhs = $op->sprevious_sibling or next;
        next unless $lhs->isa('PPI::Token::Symbol');

        my $var_name = $lhs->content;
        next unless $annotated{$var_name};

        # Look up the declared type (already resolved by TypeEnv)
        my $env = $self->_env_for_node($op);
        my $declared_type = $env->{variables}{$var_name} // next;

        next if $self->_has_type_var_cached($declared_type);

        # Infer the RHS expression type
        my $rhs = $op->snext_sibling or next;
        my $inferred = Typist::Static::Infer->infer_expr($rhs, $env, $declared_type);
        next unless defined $inferred;
        next if _contains_any($inferred);

        unless (Typist::Subtype->is_subtype($inferred, $declared_type, registry => $self->{type_env}->registry)) {
            my $vi = $var_info{$var_name};
            $self->{errors}->collect(
                kind          => 'TypeMismatch',
                message       => "Assignment to $var_name: cannot assign ${\$inferred->to_string} to ${\$declared_type->to_string}",
                file          => $self->{file},
                line          => $lhs->line_number,
                col           => $lhs->column_number,
                end_col       => $lhs->column_number + length($lhs->content),
                expected_type => $declared_type->to_string,
                actual_type   => $inferred->to_string,
                explanation   => [
                    "Declared type: ${\$declared_type->to_string}",
                    "Assigned expression type: ${\$inferred->to_string}",
                    "Assigned value is not a subtype of the declared annotation",
                ],
                suggestions   => ["Change annotation to :sig(${\$inferred->to_string})"],
                ($vi ? (related => [+{ line => $vi->{line}, col => $vi->{col} // 1, message => 'declared here' }]) : ()),
            );
        }
    }
}

sub check_call_sites :TIMED(call_sites) ($self) {
    my $te = $self->{type_env};
    Typist::Static::CallChecker->new(
        extracted     => $self->{extracted},
        registry      => $te->registry,
        errors        => $self->{errors},
        file          => $self->{file},
        ppi_doc       => $te->ppi_doc,
        env_for_node  => sub ($node) { $te->env_for_node($node) },
        resolve_type  => sub ($expr) { $te->resolve_type($expr) },
        has_type_var  => sub ($type) { $self->_has_type_var_cached($type) },
        gradual_hints => $self->{gradual_hints},
    )->check_call_sites;
}

sub check_match_exhaustiveness :TIMED(match_exhaustiveness) ($self) {
    my $words = $self->{extracted}{special_words}{match} // [];

    for my $word (@$words) {
        next unless $word->content eq 'match';

        my $env = $self->_env_for_node($word);
        my $target = $word->snext_sibling // next;
        my $target_type = Typist::Static::Infer->infer_expr($target, $env);
        my $data_def = $self->_resolve_match_data_type($target_type) // next;

        my ($seen, $has_fallback) = $self->_collect_match_arms($word);
        next if $has_fallback;

        my $variants = $data_def->variants // next;
        my @missing = grep { !$seen->{$_} } sort keys %$variants;
        next unless @missing;

        $self->{errors}->collect(
            kind        => 'NonExhaustiveMatch',
            message     => "Non-exhaustive match: missing arm(s) for " . join(', ', @missing),
            file        => $self->{file},
            line        => $word->line_number,
            col         => $word->column_number,
            end_col     => $word->column_number + length($word->content),
            explanation => [
                "Matched type: " . $data_def->name,
                "Covered arms: " . (keys(%$seen) ? join(', ', sort keys %$seen) : '(none)'),
                "Missing variants: " . join(', ', @missing),
            ],
            suggestions => [
                (map { "Add match arm '$_ => sub { ... }'" } @missing),
                "Add fallback arm '_ => sub { ... }'",
            ],
        );
    }
}

# ── Phase 5: Function-Level Checks ──────────────

sub check_function_returns :TIMED_ACC(function_checks.returns) ($self, $name) {
    my $fn = $self->{extracted}{functions}{$name};
    my $returns_expr = $fn->{returns_expr} // return;
    $fn->{block} // return;

    my $declared = $self->_resolve_type($returns_expr);
    return unless defined $declared;

    return if $self->_has_type_var_cached($declared);

    my $returns = $fn->{return_values} // [];
    for my $entry (@$returns) {
        my $ret = $entry->{return_word};
        my $val = $entry->{value} // next;

        my $ret_env = $self->_env_for_node($ret);
        my $inferred = $self->_infer_expr_cached($val, $ret_env, $declared);
        next unless defined $inferred;
        if (_contains_any($inferred)) {
            $self->_emit_gradual_hint($name, $val, $inferred, 'return value');
            next;
        }

        unless (Typist::Subtype->is_subtype($inferred, $declared, registry => $self->{type_env}->registry)) {
            $self->{errors}->collect(
                kind          => 'TypeMismatch',
                message       => "Return value of $name(): cannot return ${\$inferred->to_string} as ${\$declared->to_string}",
                file          => $self->{file},
                line          => $val->line_number,
                col           => $val->column_number,
                end_col       => $val->column_number + length($val->content),
                expected_type => $declared->to_string,
                actual_type   => $inferred->to_string,
                explanation   => [
                    "Function return type: ${\$declared->to_string}",
                    "Returned expression type: ${\$inferred->to_string}",
                    "Returned value is not a subtype of the declared return type",
                ],
                suggestions   => ["Change return type to ${\$inferred->to_string}"],
                related       => [+{ line => $fn->{line}, col => $fn->{col} // 1, message => "$name() declared here" }],
            );
        }
    }

    # ── Implicit return (last expression) ──
    # Void return type — implicit value is irrelevant
    return if $declared->is_atom && $declared->name eq 'Void';

    # Use node-aware env for implicit return (accounts for early return narrowing)
    my $last_stmt = $fn->{last_stmt} // return;
    my $last_first = $fn->{last_first} // $last_stmt;
    my $impl_env = $self->_env_for_node($last_first);
    $self->_check_implicit_return_of_stmt($last_stmt, $impl_env, $declared, $name);
}

sub _resolve_match_data_type ($self, $type, $depth = 0) {
    return undef unless $type;
    return undef if $depth > 4;

    my $registry = $self->{type_env}->registry // return undef;

    return $type if $type->is_data;

    if ($type->is_param) {
        my $dt = $registry->lookup_datatype("$type->base");
        return $dt if $dt;
    }

    if ($type->is_alias) {
        my $resolved = eval { $registry->lookup_type($type->alias_name) };
        return undef if $@;
        return $self->_resolve_match_data_type($resolved, $depth + 1);
    }

    if ($type->is_atom) {
        my $dt = $registry->lookup_datatype($type->name);
        return $dt if $dt;
    }

    undef;
}

sub _collect_match_arms ($self, $match_word) {
    my %seen;
    my $has_fallback = 0;
    my $sib = $match_word->snext_sibling;

    while ($sib) {
        last if $sib->isa('PPI::Token::Structure') && $sib->content eq ';';

        if (($sib->isa('PPI::Token::Word') && $sib->content ne 'sub')
            || ($sib->isa('PPI::Token::Magic') && $sib->content eq '_'))
        {
            my $after = $sib->snext_sibling;
            if ($after && $after->isa('PPI::Token::Operator') && $after->content eq '=>') {
                if ($sib->content eq '_') {
                    $has_fallback = 1;
                } else {
                    $seen{$sib->content} = 1;
                }
            }
        }

        $sib = $sib->snext_sibling;
    }

    (\%seen, $has_fallback);
}

# ── Phase 6: Collection ─────────────────────────

# Collect inferred return types for unannotated functions (for inlay hints).
sub collect_fn_return_types ($self) {
    for my $name (sort keys $self->{extracted}{functions}->%*) {
        my $fn = $self->{extracted}{functions}{$name};
        next unless $fn->{unannotated};
        my @types;

        for my $entry (($fn->{return_values} // [])->@*) {
            my $ret = $entry->{return_word};
            my $val = $entry->{value} // next;
            my $t = $self->_infer_expr_cached($val, $self->_env_for_node($ret));
            push @types, $t if $t;
        }

        # Implicit return (last expression)
        my $last = $fn->{last_stmt};
        my $first = $fn->{last_first};
        if ($last && $first && !($first->isa('PPI::Token::Word') && $first->content eq 'return')) {
            my $impl_env = $self->_env_for_node($last);
            my $t = $self->_infer_expr_cached($last, $impl_env)
                 // $self->_infer_expr_cached($first, $impl_env);
            push @types, $t if $t;
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

sub collect_callback_params ($self) {
    $self->_collect_match_callback_params;
    $self->{_callback_param_types} = Typist::Static::Infer->callback_params;
}

# ── Private Methods ──────────────────────────────

# Proactively walk standalone match/map/grep/sort/handle expressions
# so their callback params are collected for LSP hover/inlay hints.
sub _collect_match_callback_params ($self) {
    for my $kind (qw(match map grep sort handle)) {
        my $words = $self->{extracted}{special_words}{$kind} // [];
        for my $word (@$words) {
            my $env = $self->_env_for_node($word);
            Typist::Static::Infer->infer_expr($word, $env);
        }
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
    my $inferred = $self->_infer_expr_cached($stmt, $env, $declared)
                // $self->_infer_expr_cached($first, $env, $declared);
    return unless defined $inferred;
    if (_contains_any($inferred)) {
        $self->_emit_gradual_hint($name, $first, $inferred, 'implicit return');
        return;
    }

    unless (Typist::Subtype->is_subtype($inferred, $declared, registry => $self->{type_env}->registry)) {
        my $fn_info = $self->{extracted}{functions}{$name};
        $self->{errors}->collect(
            kind          => 'TypeMismatch',
            message       => "Implicit return of $name(): cannot return ${\$inferred->to_string} as ${\$declared->to_string}",
            file          => $self->{file},
            line          => $first->line_number,
            col           => $first->column_number,
            end_col       => $first->column_number + length($first->content),
            expected_type => $declared->to_string,
            actual_type   => $inferred->to_string,
            explanation   => [
                "Function return type: ${\$declared->to_string}",
                "Implicit return expression type: ${\$inferred->to_string}",
                "Implicit result is not a subtype of the declared return type",
            ],
            suggestions   => ["Change return type to ${\$inferred->to_string}"],
            ($fn_info ? (related => [+{ line => $fn_info->{line}, col => $fn_info->{col} // 1, message => "$name() declared here" }]) : ()),
        );
    }
}

# ── Delegation to TypeEnv ───────────────────────

sub _env_for_node ($self, $node) { $self->{type_env}->env_for_node($node) }
sub _fn_env       ($self, $fn)   { $self->{type_env}->fn_env($fn) }
sub _resolve_type ($self, $expr) { $self->{type_env}->resolve_type($expr) }

sub _infer_expr_cached ($self, $node, $env, $expected = undef) {
    my $node_key = ref($node) ? refaddr($node) : "$node";
    my $env_key = ref($env) ? refaddr($env) : "$env";
    my $expected_key = defined $expected ? $expected->to_string : '';
    my $cache_key = join "\0", $node_key, $env_key, $expected_key;
    return $self->{_infer_expr_cache}{$cache_key} if exists $self->{_infer_expr_cache}{$cache_key};
    return $self->{_infer_expr_cache}{$cache_key} = Typist::Static::Infer->infer_expr($node, $env, $expected);
}

sub _has_type_var_cached ($self, $type) {
    my $key = ref($type) ? refaddr($type) : "$type";
    return $self->{_has_type_var_cache}{$key} if exists $self->{_has_type_var_cache}{$key};
    return $self->{_has_type_var_cache}{$key} = _has_type_var($type);
}

# ── GradualHint Emission ───────────────────────

sub _emit_gradual_hint ($self, $name, $node, $inferred, $context) {
    return unless $self->{gradual_hints};
    $self->{errors}->collect(
        kind    => 'GradualHint',
        message => "$context of $name() not checked: inferred type contains Any (${\$inferred->to_string})",
        file    => $self->{file},
        line    => $node->line_number,
        col     => $node->column_number,
        end_col => $node->column_number + length($node->content),
    );
}

# ── Helpers ─────────────────────────────────────

sub _has_type_var ($type) {
    return 1 if $type->is_var;
    return scalar $type->free_vars;
}

# Widen literal types for mutable variable bindings.
sub _widen_literal ($type) {
    if ($type->is_literal) {
        my $base = $type->base_type;
        $base = 'Int' if $base eq 'Bool';
        return Typist::Type::Atom->new($base);
    }
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

# Check whether a type transitively contains Any (gradual typing marker).
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

__END__

=head1 NAME

Typist::Static::TypeChecker - Static type mismatch detection

=head1 DESCRIPTION

PPI-based checker that detects type mismatches at variable initializers,
assignments, call sites, and return statements.  Delegates environment
construction to L<Typist::Static::TypeEnv>, then validates each usage
site against the L<Typist::Subtype> relation.

=head2 new

    # New style (with pre-built TypeEnv):
    my $tc = Typist::Static::TypeChecker->new(
        type_env  => $type_env,
        errors    => $error_collector,
        extracted => $extracted,
        file      => $filename,
    );

    # Backward-compatible (builds TypeEnv internally):
    my $tc = Typist::Static::TypeChecker->new(
        registry  => $registry,
        errors    => $error_collector,
        extracted => $extracted,
        ppi_doc   => $ppi_doc,
        file      => $filename,
    );

=head2 analyze

Run the full type-checking pipeline (backward-compatible entry point).

=head2 check_variables / check_assignments / check_call_sites

File-level checks (Phase 4).

=head2 check_function_returns

    $tc->check_function_returns($name);

Per-function return type check (Phase 5).

=head2 collect_fn_return_types / collect_callback_params

Collection phase for LSP hints (Phase 6).

=cut
