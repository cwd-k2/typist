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
    $self->{env} = $self->_build_env;
    $self->_check_variable_initializers;
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

# ── Call Site Check ──────────────────────────────

sub _check_call_sites ($self) {
    my $ppi_doc = $self->{ppi_doc} // return;
    my $words = $ppi_doc->find('PPI::Token::Word') || [];

    for my $word (@$words) {
        my $name = $word->content;

        # Try local extraction first, then registry for cross-package calls (Pkg::func)
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
            next unless $cross_pkg;
            $fn = $cross_pkg;
        }

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
            my $inferred = Typist::Static::Infer->infer_expr($args[$i], $self->{env});
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

            my $inferred = Typist::Static::Infer->infer_expr($val, $self->{env});
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
    }
}

# ── Helpers ──────────────────────────────────────

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

sub _extract_args ($self, $list) {
    # List contains an Expression with comma-separated args
    my $expr = $list->find_first('PPI::Statement::Expression')
            // $list->find_first('PPI::Statement');
    return () unless $expr;

    # Group Word+List pairs as a single function-call argument
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
    }

    @args;
}

1;
