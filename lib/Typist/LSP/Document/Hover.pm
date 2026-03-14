package Typist::LSP::Document;
use v5.40;

# ── Hover / Symbol Resolution ──────────────────
#
# symbol_at dispatcher and all hover resolution paths:
# struct key, handler op, generic instantiation, keyword hover,
# builtin types, registry synthesis.

my %BUILTINS = map { $_ => 1 } Typist::Prelude->builtin_names;

my %BUILTIN_TYPES = (
    # Primitives
    Int    => { detail => 'Integer type',                           hierarchy => 'Bool <: Int <: Double <: Num <: Any' },
    Str    => { detail => 'String type',                            hierarchy => 'Str <: Any' },
    Double => { detail => 'Floating-point type',                    hierarchy => 'Int <: Double <: Num <: Any' },
    Num    => { detail => 'Numeric supertype (Int, Double)',        hierarchy => 'Int <: Double <: Num <: Any' },
    Bool   => { detail => 'Boolean type',                           hierarchy => 'Bool <: Int <: Double <: Num <: Any' },
    Any    => { detail => 'Top type — compatible with all types' },
    Void   => { detail => 'Unit return type' },
    Never  => { detail => 'Bottom type — subtype of all types' },
    Undef  => { detail => 'Undefined value type. Maybe[T] = T | Undef', hierarchy => 'Undef <: Any' },
    # Parametric constructors
    ArrayRef => { detail => 'Scalar reference to array. What [LIST] produces',        params => 'T' },
    HashRef  => { detail => 'Scalar reference to hash. What +{LIST} produces',        params => 'K, V' },
    Array    => { detail => 'List type. What grep/map/sort/@deref produce',            params => 'T' },
    Hash     => { detail => 'List type for hash entries',                               params => 'K, V' },
    Maybe    => { detail => 'Nullable type. Maybe[T] = T | Undef',                     params => 'T' },
    Tuple    => { detail => 'Fixed-length heterogeneous array reference',               params => 'T, U, ...' },
    Ref      => { detail => 'Generic scalar reference',                                 params => 'T' },
    CodeRef  => { detail => 'Function reference type. CodeRef[A -> R ! E]',             params => 'A -> R' },
    Handler  => { detail => 'Effect handler record type',                               params => 'E' },
    Record   => { detail => 'Structural record type (plain hashrefs)',                   params => 'k => V, ...' },
);

# Find the symbol at a given line/col (0-indexed).
sub symbol_at ($self, $line, $col) {
    my $result = $self->{result} // return undef;
    my $symbols = $result->{symbols} // return undef;

    # Primary: match by word under cursor
    my $wr = $self->_word_range_at($line, $col) // return undef;
    return undef if $self->_is_in_comment($line, $col);
    return undef if $self->_is_in_string($line, $col);
    my $word = $wr->{word};
    my $range = +{
        start => +{ line => $line, character => $wr->{start} },
        end   => +{ line => $line, character => $wr->{end} },
    };

    # Helper to attach range to a symbol and return it
    my $with_range = sub ($sym) {
        $sym->{range} = $range;
        $sym;
    };

    # Accessor check: $var->field resolves struct field types
    if (my $field_sym = $self->_resolver->resolve_accessor_hover($line, $col, $word)) {
        return $with_range->($field_sym);
    }

    my $sym = $self->_find_best_symbol($symbols, $word, $line);
    if ($sym) {
        # For generic functions at call sites, add instantiation info
        if (($sym->{kind} // '') eq 'function' && $sym->{generics} && @{$sym->{generics}}) {
            if (my $registry = ($self->{result} // +{})->{registry}) {
                my $pkg = ($self->{result}{extracted}{package} // 'main');
                my $sig = $registry->lookup_function($pkg, $word)
                       // $registry->search_function_by_name($word);
                if ($sig && $sig->{generics} && @{$sig->{generics}}) {
                    if (my $bindings = $self->_call_site_bindings($sig, $line, $col)) {
                        $sym = _apply_bindings_to_symbol($sym, $bindings);
                    }
                }
            }
        }
        return $with_range->($sym);
    }

    # Try without sigil (e.g. cursor on "foo" matches function "foo")
    (my $bare = $word) =~ s/^[\$\@%]//;
    if ($bare ne $word) {
        my $sym = $self->_find_best_symbol($symbols, $bare, $line);
        return $with_range->($sym) if $sym;
    }

    # Check if word is a hash key (followed by =>)
    my $is_hash_key = do {
        my $text = $self->_lines->[$line] // '';
        $wr->{end} < length($text)
            && substr($text, $wr->{end}) =~ /\A\s*=>/;
    };

    # Struct constructor key: Point(x => 1) — hover on "x" shows field info
    if ($is_hash_key) {
        if (my $field_sym = $self->_resolve_struct_key_hover($word, $line, $col)) {
            return $with_range->($field_sym);
        }
        # Handler operation key: Effect => +{ read => sub { }, ... }
        if (my $op_sym = $self->_resolve_handler_op_hover($word, $line, $col)) {
            return $with_range->($op_sym);
        }
    }

    # Fallback: synthesize symbol for Perl builtins
    my $builtin_name = $bare // $word;
    if ($BUILTINS{$builtin_name} && !$is_hash_key) {
        # Use actual Prelude signature from CORE registry when available
        if (my $registry = $result->{registry}) {
            if (my $sig = $registry->lookup_function('CORE', $builtin_name)) {
                my $sym = _synthesize_function_symbol($builtin_name, $sig);
                $sym->{builtin} = 1;
                $sym->{typist_builtin} = 1 if Typist::Prelude->is_typist_builtin($builtin_name);
                return $with_range->($sym);
            }
        }
        return $with_range->(sym_function(
            name         => $builtin_name,
            params_expr  => ['Any...'],
            returns_expr => 'Any',
            builtin      => 1,
            (Typist::Prelude->is_typist_builtin($builtin_name) ? (typist_builtin => 1) : ()),
        ));
    }

    # Fallback: registry lookup for cross-package or constructor symbols
    if (my $registry = $result->{registry}) {
        my $lookup_name = $bare // $word;

        # Function lookup: skip hash keys (read => sub { } should not
        # resolve to CORE::read).  Type-level lookups below still apply.
        if (!$is_hash_key) {
            if ($word =~ /::/) {
                # Qualified name: Pkg::func — only show hover on function name part
                return undef unless $self->_cursor_on_func_part($line, $col, $word);

                my ($pkg, $fname) = $word =~ /\A(.+)::(\w+)\z/;
                if ($pkg && $fname) {
                    if (my $sig = $registry->lookup_function($pkg, $fname)) {
                        my $bindings = $self->_call_site_bindings($sig, $line, $col);
                        return $with_range->(_synthesize_function_symbol($fname, $sig, $bindings));
                    }
                }
            } else {
                # Unqualified: try current package first
                my $pkg = $result->{extracted}{package} // 'main';
                if (my $sig = $registry->lookup_function($pkg, $lookup_name)) {
                    my $bindings = $self->_call_site_bindings($sig, $line, $col);
                    return $with_range->(_synthesize_function_symbol($lookup_name, $sig, $bindings));
                }

                # Then search all packages (Exporter-imported constructors, etc.)
                if (my $sig = $registry->search_function_by_name($lookup_name)) {
                    my $bindings = $self->_call_site_bindings($sig, $line, $col);
                    return $with_range->(_synthesize_function_symbol($lookup_name, $sig, $bindings));
                }
            }
        }

        # Type-level symbols: newtype, typedef, datatype, effect, typeclass
        my $provenance = $registry->defined_in($lookup_name);
        if (my $nt = $registry->lookup_newtype($lookup_name)) {
            return $with_range->(sym_newtype(
                name       => $lookup_name,
                type       => $nt->inner->to_string,
                defined_in => $provenance,
            ));
        }
        if ($registry->has_alias($lookup_name)) {
            my $resolved = $registry->lookup_type($lookup_name);
            if ($resolved) {
                return $with_range->(sym_typedef(
                    name       => $lookup_name,
                    type       => $resolved->to_string,
                    defined_in => $provenance,
                ));
            }
        }
        if (my $dt = $registry->lookup_datatype($lookup_name)) {
            my @tp = $dt->type_params;
            my @variants;
            for my $tag (sort keys %{$dt->variants // +{}}) {
                my @types = ($dt->variants->{$tag} // [])->@*;
                my $spec = @types
                    ? '(' . join(', ', map { $_->to_string } @types) . ')'
                    : '';
                if ($dt->is_gadt && $dt->return_types->{$tag}) {
                    $spec .= ' -> ' . $dt->return_types->{$tag}->to_string;
                }
                push @variants, +{ tag => $tag, spec => $spec };
            }
            return $with_range->(sym_datatype(
                name        => $lookup_name,
                type        => $dt->to_string,
                type_params => \@tp,
                variants    => \@variants,
                defined_in  => $provenance,
            ));
        }
        if (my $st = $registry->lookup_struct($lookup_name)) {
            my @field_descs;
            my %req = $st->record->required_fields;
            my %opt = $st->record->optional_fields;
            for my $f (sort keys %req) {
                push @field_descs, "$f: " . $req{$f}->to_string;
            }
            for my $f (sort keys %opt) {
                push @field_descs, "$f?: " . $opt{$f}->to_string;
            }
            return $with_range->(sym_struct(
                name       => $lookup_name,
                fields     => \@field_descs,
                defined_in => $provenance,
            ));
        }
        if (my $eff = $registry->lookup_effect($lookup_name)) {
            my @op_names;
            my %operations;
            for my $op_name ($eff->op_names) {
                push @op_names, $op_name;
                my $op_type = $eff->get_op_type($op_name);
                $operations{$op_name} = $op_type ? $op_type->to_string : $eff->get_op($op_name);
            }
            return $with_range->(sym_effect(
                name       => $lookup_name,
                op_names   => \@op_names,
                operations => \%operations,
                defined_in => $provenance,
            ));
        }
        if ($registry->has_typeclass($lookup_name)) {
            my $tc = $registry->lookup_typeclass($lookup_name);
            my @method_names;
            my %methods;
            if ($tc) {
                my %m = $tc->methods;
                @method_names = sort keys %m;
                %methods = %m;
            }
            return $with_range->(sym_typeclass(
                name         => $lookup_name,
                var_spec     => $tc ? $tc->var : undef,
                method_names => \@method_names,
                methods      => \%methods,
                defined_in   => $provenance,
            ));
        }
    }

    # Built-in type hover (primitives and parametric constructors)
    {
        my $type_name = $bare // $word;
        if (my $bt = $BUILTIN_TYPES{$type_name}) {
            return $with_range->(+{
                kind => 'builtin_type',
                name => $type_name,
                %$bt,
            });
        }
    }

    # Keyword hover: match / handle / scoped
    if ($word eq 'match' || $word eq 'handle' || $word eq 'scoped') {
        if (my $kw_sym = $self->_resolve_keyword_hover($word, $line, $col)) {
            return $with_range->($kw_sym);
        }
    }

    undef;
}

# ── Keyword Hover ───────────────────────────────

# Find PPI::Token::Word at the given LSP position (0-indexed).
sub _ppi_word_at ($self, $line, $col) {
    my $ppi_doc = ($self->{result} // return undef)->{extracted}{ppi_doc} // return undef;
    my $ppi_line = $line + 1;  # LSP 0-indexed → PPI 1-indexed
    my $tokens = $ppi_doc->find('PPI::Token::Word') || [];
    for my $t (@$tokens) {
        next unless $t->line_number == $ppi_line;
        my $t_col = $t->column_number - 1;  # PPI 1-indexed → 0-indexed
        next unless $col >= $t_col && $col < $t_col + length($t->content);
        return $t;
    }
    undef;
}

# Resolve struct constructor key: Point(x => 1) — hover on "x".
sub _resolve_struct_key_hover ($self, $word, $line, $col) {
    my $result   = $self->{result} // return undef;
    my $registry = $result->{registry} // return undef;

    my $ppi_word = $self->_ppi_word_at($line, $col) // return undef;
    return undef unless $ppi_word->content eq $word;

    # Walk up to enclosing Structure::List
    my $parent = $ppi_word->parent;
    while ($parent && !$parent->isa('PPI::Structure::List')) {
        $parent = $parent->parent;
    }
    return undef unless $parent;

    # Constructor name is the previous sibling of the List
    my $prev = $parent->sprevious_sibling or return undef;
    return undef unless $prev->isa('PPI::Token::Word');
    my $struct_name = $prev->content;

    my $st = $registry->lookup_struct($struct_name) // return undef;

    my %req = $st->record->required_fields;
    my %opt = $st->record->optional_fields;

    if (my $type = $req{$word}) {
        return sym_field(
            name        => $word,
            type        => $type->to_string,
            struct_name => $struct_name,
        );
    }
    if (my $type = $opt{$word}) {
        return sym_field(
            name        => $word,
            type        => $type->to_string,
            struct_name => $struct_name,
            optional    => 1,
        );
    }

    undef;
}

# Resolve handler operation key hover: read => sub { } inside Effect => +{ ... }
sub _resolve_handler_op_hover ($self, $word, $line, $col) {
    my $result   = $self->{result} // return undef;
    my $registry = $result->{registry} // return undef;

    my $ppi_word = $self->_ppi_word_at($line, $col) // return undef;
    return undef unless $ppi_word->content eq $word;

    # Walk up to find enclosing +{...} (PPI::Structure::Constructor or Block)
    my $constr = $ppi_word->parent;
    while ($constr && !$constr->isa('PPI::Structure::Block')
                   && !($constr->isa('PPI::Structure::Constructor'))) {
        $constr = $constr->parent;
    }
    return undef unless $constr;

    # Look for Effect => +{...} pattern.
    # PPI parses +{...} as Operator(+) + Constructor({...}), so skip the '+'.
    my $prev = $constr->sprevious_sibling or return undef;
    if ($prev->isa('PPI::Token::Operator') && $prev->content eq '+') {
        $prev = $prev->sprevious_sibling or return undef;
    }
    my $arrow = $prev;
    return undef unless $arrow->isa('PPI::Token::Operator') && $arrow->content eq '=>';
    my $effect_token = $arrow->sprevious_sibling or return undef;

    my ($effect_name, @type_args_str);
    if ($effect_token->isa('PPI::Token::Word')) {
        $effect_name = $effect_token->content;
    } elsif ($effect_token->isa('PPI::Token::Symbol')) {
        # Scoped: $var => +{...} — resolve variable type to extract effect name and type args
        my $resolver = $self->_resolver;
        my $var_type = $resolver->resolve_var_type($effect_token->content, $line);
        if ($var_type && $var_type =~ /EffectScope\[(\w+)(?:\[(.+)\])?\]/) {
            $effect_name = $1;
            @type_args_str = split /,\s*/, ($2 // '');
        }
    }
    return undef unless $effect_name;

    my $eff = $registry->lookup_effect($effect_name) // return undef;
    my $op_type = $eff->get_op_type($word) // return undef;

    # Substitute type params with concrete type args if available
    my @type_params = $eff->type_params;
    if (@type_params && @type_args_str) {
        my %subst;
        for my $i (0 .. $#type_params) {
            last if $i > $#type_args_str;
            my $concrete = eval { Typist::Parser->parse($type_args_str[$i]) };
            $subst{$type_params[$i]} = $concrete if $concrete;
        }
        $op_type = $op_type->substitute(\%subst) if %subst;
    }

    # Include effect type params as generics when not substituted
    my @generics;
    if (@type_params && !@type_args_str) {
        @generics = @type_params;
    }

    sym_function(
        name         => $word,
        params_expr  => [$op_type->is_func ? (map { $_->to_string } $op_type->params) : ()],
        returns_expr => $op_type->is_func ? $op_type->returns->to_string : $op_type->to_string,
        (@generics ? (generics => \@generics) : ()),
    );
}

# Collect generic type bindings at a call site for instantiation display.
# Returns { VarName => Type } or undef if not a generic call site.
sub _call_site_bindings ($self, $sig, $line, $col) {
    # Only for generic functions
    return undef unless $sig->{generics} && @{$sig->{generics}};

    my $result   = $self->{result} // return undef;
    my $registry = $result->{registry} // return undef;

    # Find PPI word at this position
    my $ppi_word = $self->_ppi_word_at($line, $col) // return undef;

    # Find the argument list: func(...) — next sibling should be Structure::List
    my $list = $ppi_word->snext_sibling;
    return undef unless $list && $list->isa('PPI::Structure::List');

    # Build env for inference from analysis result (symbols + extracted functions)
    my $extracted = $result->{extracted} // return undef;
    my %functions;
    for my $name (keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};
        next if $fn->{unannotated};
        if (my $ret_expr = $fn->{returns_expr}) {
            my $type = eval { Typist::Parser->parse($ret_expr) };
            $functions{$name} = $type if $type;
        }
    }

    # Populate variables from analyzed symbols (scoped to call site line)
    my $symbols = $result->{symbols} // [];
    my $ppi_line = $line + 1;  # LSP 0-indexed → PPI 1-indexed
    my %variables;
    for my $sym (@$symbols) {
        next unless ($sym->{kind} // '') =~ /\A(?:variable|parameter)\z/;
        next unless defined $sym->{type} && $sym->{type} ne 'Any';
        # Scope check: variable must be visible at the call site
        if ($sym->{scope_start} && $sym->{scope_end}) {
            next unless $ppi_line >= $sym->{scope_start} && $ppi_line <= $sym->{scope_end};
        }
        my $type = eval { Typist::Parser->parse($sym->{type}) };
        $variables{$sym->{name}} = $type if $type;
    }

    my $env = +{
        variables => \%variables,
        functions => \%functions,
        registry  => $registry,
        package   => $extracted->{package} // 'main',
    };

    # Extract arg nodes (simplified: just get immediate children)
    my $expr = $list->schild(0);
    return undef unless $expr && $expr->isa('PPI::Statement');

    my @arg_nodes;
    my @children = $expr->schildren;
    my $i = 0;
    while ($i <= $#children) {
        my $child = $children[$i];
        if ($child->isa('PPI::Token::Operator') && $child->content eq ',') {
            $i++; next;
        }
        push @arg_nodes, $child;
        # Skip anonymous sub continuations
        if ($child->isa('PPI::Token::Word') && $child->content eq 'sub'
            && !($child->parent && $child->parent->isa('PPI::Statement::Sub'))) {
            $i++;
            $i++ if $i <= $#children && ($children[$i]->isa('PPI::Token::Prototype')
                                       || $children[$i]->isa('PPI::Structure::List'));
            $i++ if $i <= $#children && $children[$i]->isa('PPI::Structure::Block');
            next;
        }
        # Skip function call arg list
        if ($child->isa('PPI::Token::Word') && $child->content ne 'sub'
            && $i + 1 <= $#children
            && $children[$i + 1]->isa('PPI::Structure::List')) {
            $i += 2; next;
        }
        $i++;
    }

    return undef unless @arg_nodes;

    # 2-pass binding: Pass 1 collects from non-callback args,
    # Pass 2 re-infers callbacks with expected types from Pass 1 bindings.
    require Typist::Static::Unify;
    require Typist::Static::Infer;
    my @params = @{$sig->{params}};
    my %bindings;
    my @callback_indices;

    # Pass 1: non-callback args
    for my $j (0 .. $#params) {
        last if $j > $#arg_nodes;
        if ($arg_nodes[$j]->isa('PPI::Token::Word') && $arg_nodes[$j]->content eq 'sub') {
            push @callback_indices, $j;
            next;
        }
        my $inferred = Typist::Static::Infer->infer_expr($arg_nodes[$j], $env);
        next unless $inferred;
        Typist::Static::Unify->collect_bindings($params[$j], $inferred, \%bindings);
    }

    # Pass 2: callback args with expected type (substitute Pass 1 bindings)
    if (%bindings && @callback_indices) {
        for my $j (@callback_indices) {
            next if $j > $#arg_nodes;
            my $expected = $params[$j]->substitute(\%bindings);
            my $inferred = Typist::Static::Infer->infer_expr(
                $arg_nodes[$j], $env, $expected);
            next unless $inferred;
            Typist::Static::Unify->collect_bindings($params[$j], $inferred, \%bindings);
        }
    }

    # Pass 3: unify return type with enclosing function's expected return type
    # Resolves e.g. Err<T>(Str) -> Result[T] when enclosing returns Result[Customer]
    if ($sig->{returns} && $sig->{returns}->free_vars) {
        my $expected_ret = $self->_enclosing_return_type($line);
        if ($expected_ret) {
            Typist::Static::Unify->collect_bindings(
                $sig->{returns}, $expected_ret, \%bindings);
        }
    }

    %bindings ? \%bindings : undef;
}

# Find the return type of the function enclosing the given LSP line.
sub _enclosing_return_type ($self, $line) {
    my $extracted = ($self->{result} // return undef)->{extracted} // return undef;
    my $ppi_line = $line + 1;
    my ($best_fn, $best_span);
    for my $name (keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};
        next unless $fn->{line} && $fn->{end_line} && $fn->{returns_expr};
        next if $fn->{unannotated};
        next unless $ppi_line >= $fn->{line} && $ppi_line <= $fn->{end_line};
        my $span = $fn->{end_line} - $fn->{line};
        if (!defined $best_span || $span < $best_span) {
            $best_fn   = $fn;
            $best_span = $span;
        }
    }
    return undef unless $best_fn;
    eval { Typist::Parser->parse($best_fn->{returns_expr}) };
}

# Apply generic bindings to an extracted symbol's generics and signature for display.
# generics in extracted symbols are strings like "T", "T: Num", etc.
sub _apply_bindings_to_symbol ($sym, $bindings) {
    my @new_generics = map {
        my ($var_name) = /\A(\w+)/;
        if ($var_name && exists $bindings->{$var_name}) {
            $_ . ' = ' . $bindings->{$var_name}->to_string;
        } else {
            $_;
        }
    } @{$sym->{generics}};

    # Substitute bound type variables in params_expr and returns_expr strings
    my $subst_str = sub ($s) {
        for my $var (keys %$bindings) {
            my $repl = $bindings->{$var}->to_string;
            $s =~ s/\b\Q$var\E\b/$repl/g;
        }
        $s;
    };
    my @new_params = map { $subst_str->($_) } ($sym->{params_expr} // [])->@*;
    my $new_returns = defined $sym->{returns_expr}
        ? $subst_str->($sym->{returns_expr}) : $sym->{returns_expr};

    +{ %$sym, generics => \@new_generics, params_expr => \@new_params,
       returns_expr => $new_returns };
}

# Dispatch keyword hover for match/handle.
sub _resolve_keyword_hover ($self, $word, $line, $col) {
    my $ppi_word = $self->_ppi_word_at($line, $col) // return undef;
    return undef unless $ppi_word->content eq $word;

    return $self->_resolve_match_hover($ppi_word, $line) if $word eq 'match';
    return $self->_resolve_handle_hover($ppi_word)       if $word eq 'handle';
    return $self->_resolve_scoped_hover($ppi_word)       if $word eq 'scoped';
    undef;
}

# Resolve match keyword: find the matched expression's type and datatype info.
sub _resolve_match_hover ($self, $ppi_word, $line) {
    my $result   = $self->{result} // return undef;
    my $registry = $result->{registry} // return undef;
    my $resolver = $self->_resolver;

    # Walk siblings after 'match' to find the target expression
    my $type_str;
    my $target_name;
    my $sib = $ppi_word->next_sibling;

    # Skip whitespace
    $sib = $sib->next_sibling while $sib && $sib->isa('PPI::Token::Whitespace');

    if ($sib && $sib->isa('PPI::Token::Symbol')) {
        # match $var, ...
        $target_name = $sib->content;
        $type_str = $resolver->resolve_var_type($target_name, $line);
    } elsif ($sib && $sib->isa('PPI::Token::Word')) {
        # match func_call(...), ...
        $target_name = $sib->content . '(...)';
        $type_str = $resolver->resolve_func_return_type($sib->content, $registry);
    }

    return undef unless $type_str;

    +{
        kind        => 'match',
        target      => $target_name,
        type_str    => $type_str,
        result_type => $self->_infer_keyword_result_type($ppi_word) // '_',
    };
}

# Resolve handle keyword: find the handled effect names and their operations.
sub _resolve_handle_hover ($self, $ppi_word) {
    my $result   = $self->{result} // return undef;
    my $registry = $result->{registry} // return undef;

    # handle { BLOCK } EffectName => +{ ... }, $scoped => +{ ... }
    my $sib = $ppi_word->next_sibling;

    # Skip whitespace
    $sib = $sib->next_sibling while $sib && $sib->isa('PPI::Token::Whitespace');

    # Must see a block to confirm this is the handle keyword (not a variable name)
    return undef unless $sib && $sib->isa('PPI::Structure::Block');

    # Walk siblings after the block to collect effect names
    $sib = $sib->next_sibling;
    my @effects;
    my $resolver = $self->_resolver;
    my $handle_line = $ppi_word->line_number - 1;  # PPI 1-indexed → LSP 0-indexed

    while ($sib) {
        if ($sib->isa('PPI::Token::Word')) {
            my $name = $sib->content;
            if ($registry->lookup_effect($name)) {
                push @effects, +{ name => $name };
            }
        }
        # Scoped effect: $var => +{...} — resolve variable type to find effect name
        elsif ($sib->isa('PPI::Token::Symbol')) {
            my $next = $sib->snext_sibling;
            if ($next && $next->isa('PPI::Token::Operator') && $next->content eq '=>') {
                my $type_str = $resolver->resolve_var_type($sib->content, $handle_line);
                if ($type_str && $type_str =~ /EffectScope\[(\w+)/) {
                    push @effects, +{ name => $1, scoped => 1, var => $sib->content };
                }
            }
        }
        $sib = $sib->next_sibling;
    }

    return undef unless @effects;

    +{
        kind        => 'handle',
        name        => join(', ', map { $_->{name} } @effects),
        effects     => \@effects,
        result_type => $self->_infer_keyword_result_type($ppi_word) // '_',
    };
}

# Resolve scoped keyword: scoped('Effect[T]') or scoped 'Effect[T]'.
sub _resolve_scoped_hover ($self, $ppi_word) {
    my $result   = $self->{result} // return undef;
    my $registry = $result->{registry} // return undef;

    my $sib = $ppi_word->snext_sibling;
    return undef unless $sib;

    my $arg;
    if ($sib->isa('PPI::Structure::List')) {
        # scoped('Effect[T]')
        my $quotes = $sib->find('PPI::Token::Quote');
        $arg = $quotes->[0]->string if $quotes && @$quotes;
    }
    elsif ($sib->isa('PPI::Token::Quote')) {
        # scoped 'Effect[T]'
        $arg = $sib->string;
    }
    return undef unless $arg;

    my ($base) = $arg =~ /\A(\w+)/;
    return undef unless $base;

    +{
        kind        => 'scoped',
        name        => $arg,
        effect_name => $base,
        has_effect  => $registry->lookup_effect($base) ? 1 : 0,
        result_type => "EffectScope[$base]",
    };
}

# Infer the result type of a keyword expression from its surrounding context.
# Checks: (1) variable assignment, (2) enclosing function return annotation.
sub _infer_keyword_result_type ($self, $ppi_token) {
    my $result   = $self->{result} // return undef;
    my $resolver = $self->_resolver;

    # Walk up to the containing statement
    my $stmt = $ppi_token->parent;
    $stmt = $stmt->parent while $stmt && !$stmt->isa('PPI::Statement');
    return undef unless $stmt;

    # (1) Variable assignment: my $x = match/handle ...
    if ($stmt->isa('PPI::Statement::Variable')) {
        my @children = $stmt->children;
        for my $ch (@children) {
            next unless $ch->isa('PPI::Token::Symbol');
            my $var_name = $ch->content;
            my $line = $ppi_token->line_number - 1;  # PPI 1-indexed → LSP 0-indexed
            my $type = $resolver->resolve_var_type($var_name, $line);
            return $type if $type && $type ne 'Any';
        }
    }

    # (2) Enclosing function: look for :sig(...) return type annotation
    my $block = $stmt->parent;
    $block = $block->parent while $block && !$block->isa('PPI::Structure::Block');
    return undef unless $block;

    my $sub_word = $block->previous_sibling;
    # Walk backwards past prototype/signature, attributes, name, to find 'sub'
    while ($sub_word && !($sub_word->isa('PPI::Token::Word') && $sub_word->content eq 'sub')) {
        $sub_word = $sub_word->previous_sibling;
    }
    return undef unless $sub_word;

    # Find function name
    my $name_token = $sub_word->next_sibling;
    $name_token = $name_token->next_sibling while $name_token && $name_token->isa('PPI::Token::Whitespace');
    return undef unless $name_token && $name_token->isa('PPI::Token::Word');
    my $fn_name = $name_token->content;

    # Look up from extracted functions (hash keyed by name)
    my $functions = $result->{extracted}{functions} // +{};
    if (my $fn = $functions->{$fn_name}) {
        return $fn->{returns_expr} if $fn->{returns_expr};
    }

    # (3) Inferred function return type (unannotated functions)
    if (my $ifr = ($result->{inferred_fn_returns} // +{})->{$fn_name}) {
        return $ifr->{type} if $ifr->{type};
    }

    undef;
}

# Find the best matching symbol: prefer scoped symbols when cursor is within scope.
sub _find_best_symbol ($self, $symbols, $name, $line) {
    my $ppi_line = $line + 1;  # LSP 0-indexed → PPI 1-indexed
    my @candidates;

    for my $sym (@$symbols) {
        next unless defined $sym->{name} && $sym->{name} eq $name;
        push @candidates, $sym;
    }

    return undef unless @candidates;
    return $candidates[0] if @candidates == 1;

    # Prefer the narrowest scoped symbol containing the cursor
    my ($best_scoped, $best_span);
    for my $sym (@candidates) {
        if ($sym->{scope_start} && $sym->{scope_end}) {
            if ($ppi_line >= $sym->{scope_start} && $ppi_line <= $sym->{scope_end}) {
                my $span = $sym->{scope_end} - $sym->{scope_start};
                if (!defined $best_span || $span < $best_span) {
                    $best_scoped = $sym;
                    $best_span   = $span;
                }
            }
        }
    }

    return $best_scoped if $best_scoped;

    # Fallback: first non-scoped symbol, or first candidate
    for my $sym (@candidates) {
        return $sym unless $sym->{scope_start};
    }
    $candidates[0];
}

# ── Registry Symbol Synthesis ───────────────────

sub _synthesize_function_symbol ($name, $sig, $bindings = undef) {
    my @params_expr;
    if ($sig->{params}) {
        @params_expr = map {
            my $t = $_;
            $t = $t->substitute($bindings) if ref $t && $bindings;
            ref $t ? $t->to_string : $t;
        } @{$sig->{params}};
    }
    @params_expr = @{$sig->{params_expr}} if $sig->{params_expr} && !@params_expr;

    my $returns_expr;
    if ($sig->{returns}) {
        my $r = $sig->{returns};
        $r = $r->substitute($bindings) if ref $r && $bindings;
        $returns_expr = ref $r ? $r->to_string : $r;
    }
    $returns_expr //= $sig->{returns_expr};

    my @generics;
    if ($sig->{generics} && @{$sig->{generics}}) {
        @generics = map {
            if (ref $_ eq 'HASH') {
                my $g = $_->{name};
                my @constraints;
                push @constraints, $_->{bound_expr}          if $_->{bound_expr};
                push @constraints, $_->{tc_constraints}->@*  if $_->{tc_constraints};
                $g .= ': ' . join(' + ', @constraints) if @constraints;
                # Append call-site instantiation: A = Int
                if ($bindings && exists $bindings->{$_->{name}}) {
                    $g .= ' = ' . $bindings->{$_->{name}}->to_string;
                }
                $g;
            } else {
                my $g = $_;
                if ($bindings && exists $bindings->{$_}) {
                    $g .= ' = ' . $bindings->{$_}->to_string;
                }
                $g;
            }
        } @{$sig->{generics}};
    }

    my $eff_expr;
    if ($sig->{effects}) {
        $eff_expr = ref $sig->{effects} ? $sig->{effects}->to_string : $sig->{effects};
    }

    sym_function(
        name         => $name,
        params_expr  => \@params_expr,
        returns_expr => $returns_expr,
        generics     => \@generics,
        eff_expr     => $eff_expr,
        ($sig->{constructor}        ? (constructor        => 1) : ()),
        ($sig->{struct_constructor} ? (struct_constructor => 1) : ()),
        (defined $sig->{protocol_transitions} ? (protocol_transitions => $sig->{protocol_transitions}) : ()),
    );
}

1;
