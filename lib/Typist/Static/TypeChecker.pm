package Typist::Static::TypeChecker;
use v5.40;

use Typist::Static::Infer;
use Typist::Parser;
use Typist::Subtype;

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
    $self->_check_variable_initializers;
    $self->_check_call_sites;
    $self->_check_return_types;
}

# ── Variable Initializer Check ───────────────────

sub _check_variable_initializers ($self) {
    for my $var ($self->{extracted}{variables}->@*) {
        my $init_node = $var->{init_node} // next;

        my $inferred = Typist::Static::Infer->infer_expr($init_node);
        next unless defined $inferred;

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

# ── Call Site Check ──────────────────────────────

sub _check_call_sites ($self) {
    my $ppi_doc = $self->{ppi_doc} // return;
    my $words = $ppi_doc->find('PPI::Token::Word') || [];

    for my $word (@$words) {
        my $name = $word->content;
        my $fn = $self->{extracted}{functions}{$name} // next;

        # Skip if the word is part of a sub declaration
        my $parent = $word->parent;
        next if $parent && $parent->isa('PPI::Statement::Sub');

        # Find the argument list — next sibling should be a List
        my $next = $word->snext_sibling // next;
        next unless $next->isa('PPI::Structure::List');

        # Skip generic functions (type variables can't be resolved statically)
        next if $fn->{generics} && $fn->{generics}->@*;

        my @param_exprs = $fn->{params_expr}->@*;
        next unless @param_exprs;

        # Extract argument expressions from the list
        my @args = $self->_extract_args($next);

        my $n = @param_exprs < @args ? @param_exprs : @args;
        for my $i (0 .. $n - 1) {
            my $inferred = Typist::Static::Infer->infer_expr($args[$i]);
            next unless defined $inferred;

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

# ── Return Type Check ───────────────────────────

sub _check_return_types ($self) {
    for my $name (sort keys $self->{extracted}{functions}->%*) {
        my $fn = $self->{extracted}{functions}{$name};
        my $returns_expr = $fn->{returns_expr} // next;
        my $block = $fn->{block} // next;

        my $declared = $self->_resolve_type($returns_expr);
        next unless defined $declared;

        next if $self->_has_type_var($declared);

        # Find return statements within the block
        my $returns = $block->find('PPI::Token::Word') || [];
        for my $ret (@$returns) {
            next unless $ret->content eq 'return';

            my $val = $ret->snext_sibling // next;
            # skip 'return;' (bare return)
            next if $val->isa('PPI::Token::Structure') && $val->content eq ';';

            my $inferred = Typist::Static::Infer->infer_expr($val);
            next unless defined $inferred;

            unless (Typist::Subtype->is_subtype($inferred, $declared)) {
                $self->{errors}->collect(
                    kind    => 'TypeMismatch',
                    message => "Return value of $name(): expected ${\$declared->to_string}, got ${\$inferred->to_string}",
                    file    => $self->{file},
                    line    => $ret->line_number,
                );
            }
        }
    }
}

# ── Helpers ──────────────────────────────────────

sub _resolve_type ($self, $expr) {
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

sub _extract_args ($self, $list) {
    # List contains an Expression with comma-separated args
    my $expr = $list->find_first('PPI::Statement::Expression')
            // $list->find_first('PPI::Statement');
    return () unless $expr;

    my @args;
    for my $child ($expr->schildren) {
        next if $child->isa('PPI::Token::Operator') && $child->content eq ',';
        push @args, $child;
    }

    @args;
}

1;
