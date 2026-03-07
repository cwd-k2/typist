package Typist::LSP::Document;
use v5.40;

our $VERSION = '0.01';

use Typist::Static::Analyzer;
use Typist::Parser;
use Typist::Prelude;
use Typist::LSP::Transport;
use Typist::LSP::Document::Resolver;
use Typist::Static::SymbolInfo qw(
    sym_function sym_variable sym_typedef sym_newtype
    sym_effect sym_typeclass sym_datatype sym_struct sym_field sym_method
);

# ── Perl Builtins ───────────────────────────────

my %BUILTINS = map { $_ => 1 } Typist::Prelude->builtin_names;

# ── Built-in Type Descriptions ─────────────────

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

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        uri     => $args{uri},
        content => $args{content} // '',
        version => $args{version} // 0,
        result  => undef,
        lines   => undef,
    }, $class;
}

# ── Accessors ────────────────────────────────────

sub uri     ($self) { $self->{uri} }
sub content ($self) { $self->{content} }
sub version ($self) { $self->{version} }
sub result  ($self) { $self->{result} }

sub update ($self, $content, $version) {
    $self->{content}   = $content;
    $self->{version}   = $version;
    $self->{result}    = undef;
    $self->{extracted} = undef;  # content changed — must re-extract
    $self->{lines}     = undef;
}

sub _resolver ($self) {
    Typist::LSP::Document::Resolver->new(
        result => $self->{result},
        lines  => $self->_lines,
    );
}

# Delegate methods for external callers (Completion, Server)
sub resolve_var_type ($self, $var_name, $line = undef) {
    $self->_resolver->resolve_var_type($var_name, $line);
}

sub resolve_type_deep ($self, $type, $registry) {
    $self->_resolver->resolve_type_deep($type, $registry);
}

# Invalidate cached analysis without changing content (e.g., workspace registry changed).
sub invalidate ($self) {
    $self->{result} = undef;
}

# ── Analysis ─────────────────────────────────────

sub analyze ($self, %opts) {
    return $self->{result} if $self->{result};

    my $file = Typist::LSP::Transport::uri_to_path($self->{uri});

    # Reuse cached extracted data when only the registry changed (invalidate),
    # skipping PPI re-parse (~40-60% of analysis cost).
    my $extracted = $opts{extracted} // $self->{extracted};

    $self->{result} = Typist::Static::Analyzer->analyze(
        $self->{content},
        file               => $file,
        workspace_registry => $opts{workspace_registry},
        ($extracted           ? (extracted      => $extracted)             : ()),
        ($opts{gradual_hints} ? (gradual_hints  => $opts{gradual_hints})  : ()),
    );

    # Cache extracted for potential reuse on invalidate()
    $self->{extracted} //= $self->{result}{extracted};

    $self->{result};
}

# ── Line Index ───────────────────────────────────

sub _lines ($self) {
    $self->{lines} //= [split /\n/, $self->{content}, -1];
}

sub lines ($self) { $self->_lines }

# ── Position Queries ─────────────────────────────

# Extract the word under cursor (0-indexed line/col).
# Returns a string including sigil for variables ($foo, @bar, %baz).
sub _word_at ($self, $line, $col) {
    my $lines = $self->_lines;
    return undef unless $line < @$lines;

    my $text = $lines->[$line];
    my $len  = length $text;
    return undef unless $col < $len;

    # Expand left from $col (consume word chars, sigils, and :: pairs)
    my $start = $col;
    while ($start > 0) {
        my $ch = substr($text, $start - 1, 1);
        if ($ch =~ /[\w\$\@%]/) {
            $start--;
        } elsif ($ch eq ':' && $start >= 2 && substr($text, $start - 2, 1) eq ':') {
            $start -= 2;  # consume :: pair
        } else {
            last;
        }
    }

    # Expand right from $col (consume word chars and :: pairs)
    my $end = $col;
    while ($end < $len) {
        my $ch = substr($text, $end, 1);
        if ($ch =~ /\w/) {
            $end++;
        } elsif ($ch eq ':' && $end + 1 < $len && substr($text, $end + 1, 1) eq ':') {
            $end += 2;  # consume :: pair
        } else {
            last;
        }
    }

    return undef if $start == $end;

    my $word = substr($text, $start, $end - $start);
    # Strip leading sigil noise if it's just a bare sigil
    return undef if $word =~ /^[\$\@%]$/;
    # Reject bare :: separator
    return undef if $word eq '::';

    $word;
}

# Like _word_at but also returns word boundaries as { word, start, end }.
sub _word_range_at ($self, $line, $col) {
    my $lines = $self->_lines;
    return undef unless $line < @$lines;

    my $text = $lines->[$line];
    my $len  = length $text;
    return undef unless $col < $len;

    my $start = $col;
    while ($start > 0) {
        my $ch = substr($text, $start - 1, 1);
        if ($ch =~ /[\w\$\@%]/) {
            $start--;
        } elsif ($ch eq ':' && $start >= 2 && substr($text, $start - 2, 1) eq ':') {
            $start -= 2;
        } else {
            last;
        }
    }

    my $end = $col;
    while ($end < $len) {
        my $ch = substr($text, $end, 1);
        if ($ch =~ /\w/) {
            $end++;
        } elsif ($ch eq ':' && $end + 1 < $len && substr($text, $end + 1, 1) eq ':') {
            $end += 2;
        } else {
            last;
        }
    }

    # Handle cursor positioned on sigil ($, @, %)
    if ($start == $end && $col < $len && substr($text, $col, 1) =~ /[\$\@%]/) {
        $end = $col + 1;
        while ($end < $len && substr($text, $end, 1) =~ /\w/) {
            $end++;
        }
        $start = $col;
    }

    return undef if $start == $end;

    my $word = substr($text, $start, $end - $start);
    return undef if $word =~ /^[\$\@%]$/;
    return undef if $word eq '::';

    +{ word => $word, start => $start, end => $end };
}

# Check if the cursor position falls within a PPI comment or pod token.
sub _is_in_comment ($self, $line, $col) {
    my $ppi_doc = ($self->{result} // return 0)->{extracted}{ppi_doc} // return 0;
    my $ppi_line = $line + 1;  # LSP 0-indexed → PPI 1-indexed
    my $comments = $ppi_doc->find('PPI::Token::Comment') || [];
    for my $t (@$comments) {
        next unless $t->line_number == $ppi_line;
        return 1 if $col >= $t->column_number - 1;  # PPI 1-indexed → 0-indexed
    }
    my $pods = $ppi_doc->find('PPI::Token::Pod') || [];
    for my $t (@$pods) {
        my $start_line = $t->line_number;
        my $end_line = $start_line + (() = $t->content =~ /\n/g);
        return 1 if $ppi_line >= $start_line && $ppi_line <= $end_line;
    }
    0;
}

# Check if the cursor is on the function name part of a qualified name (Pkg::func).
# Returns true if cursor ($col) is on or after the last :: separator.
sub _cursor_on_func_part ($self, $line, $col, $word) {
    my $lines = $self->_lines;
    return 1 unless $line < @$lines;  # fallback: treat as func part

    my $text = $lines->[$line];

    # Find where the word starts by scanning left from $col
    my $start = $col;
    while ($start > 0) {
        my $ch = substr($text, $start - 1, 1);
        if ($ch =~ /[\w\$\@%]/) {
            $start--;
        } elsif ($ch eq ':' && $start >= 2 && substr($text, $start - 2, 1) eq ':') {
            $start -= 2;
        } else {
            last;
        }
    }

    # Find the position of the last :: in the word
    my $last_sep = rindex($word, '::');
    return 1 if $last_sep < 0;  # no :: found

    # Function name starts at: $start + $last_sep + 2
    my $func_start = $start + $last_sep + 2;
    $col >= $func_start;
}

# Find the symbol at a given line/col (0-indexed).
sub symbol_at ($self, $line, $col) {
    my $result = $self->{result} // return undef;
    my $symbols = $result->{symbols} // return undef;

    # Primary: match by word under cursor
    my $wr = $self->_word_range_at($line, $col) // return undef;
    return undef if $self->_is_in_comment($line, $col);
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
    return $with_range->($sym) if $sym;

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

        if ($word =~ /::/) {
            # Qualified name: Pkg::func — only show hover on function name part
            return undef unless $self->_cursor_on_func_part($line, $col, $word);

            my ($pkg, $fname) = $word =~ /\A(.+)::(\w+)\z/;
            if ($pkg && $fname) {
                if (my $sig = $registry->lookup_function($pkg, $fname)) {
                    return $with_range->(_synthesize_function_symbol($fname, $sig));
                }
            }
        } else {
            # Unqualified: try current package first
            my $pkg = $result->{extracted}{package} // 'main';
            if (my $sig = $registry->lookup_function($pkg, $lookup_name)) {
                return $with_range->(_synthesize_function_symbol($lookup_name, $sig));
            }

            # Then search all packages (Exporter-imported constructors, etc.)
            if (my $sig = $registry->search_function_by_name($lookup_name)) {
                return $with_range->(_synthesize_function_symbol($lookup_name, $sig));
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

    # Keyword hover: match / handle
    if ($word eq 'match' || $word eq 'handle') {
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

# Dispatch keyword hover for match/handle.
sub _resolve_keyword_hover ($self, $word, $line, $col) {
    my $ppi_word = $self->_ppi_word_at($line, $col) // return undef;
    return undef unless $ppi_word->content eq $word;

    return $self->_resolve_match_hover($ppi_word, $line) if $word eq 'match';
    return $self->_resolve_handle_hover($ppi_word)       if $word eq 'handle';
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

    # handle { BLOCK } EffectName => +{ ... }, EffectName2 => +{ ... }
    my $sib = $ppi_word->next_sibling;

    # Skip whitespace
    $sib = $sib->next_sibling while $sib && $sib->isa('PPI::Token::Whitespace');

    # Must see a block to confirm this is the handle keyword (not a variable name)
    return undef unless $sib && $sib->isa('PPI::Structure::Block');

    # Walk siblings after the block to collect effect names
    $sib = $sib->next_sibling;
    my @effects;
    while ($sib) {
        if ($sib->isa('PPI::Token::Word')) {
            my $name = $sib->content;
            if ($registry->lookup_effect($name)) {
                push @effects, +{ name => $name };
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

# ── Public word accessor ─────────────────────────

sub word_at ($self, $line, $col) { $self->_word_at($line, $col) }

# ── Definition Lookup ──────────────────────────

sub definition_at ($self, $line, $col) {
    my $result  = $self->{result} // return undef;
    my $symbols = $result->{symbols} // return undef;

    my $word = $self->_word_at($line, $col) // return undef;
    return undef if $self->_is_in_comment($line, $col);

    # Strip sigil for type/function lookup
    (my $bare = $word) =~ s/^[\$\@%]//;

    # Effect operation: Console::writeLine → jump to effect Console
    if ($bare =~ /\A([A-Z]\w*)::\w+\z/) {
        my $eff_name = $1;
        for my $sym (@$symbols) {
            next unless ($sym->{kind} // '') eq 'effect';
            next unless ($sym->{name} // '') eq $eff_name;
            return +{
                uri  => $self->{uri},
                line => ($sym->{line} // 1) - 1,
                col  => ($sym->{col} // 1) - 1,
                name => $eff_name,
            };
        }
    }

    # Struct field accessor: $var->field → jump to struct definition
    my $lines = $self->_lines;
    my $text_to_cursor = substr($lines->[$line] // '', 0, $col + length($bare));
    if ($text_to_cursor =~ /(\$\w+)\s*->\s*\Q$bare\E\s*\z/ && $bare !~ /::/) {
        my $var = $1;
        my $resolver = $self->_resolver;
        my $type_str = $resolver->resolve_var_type($var, $line);
        if ($type_str) {
            my $type = eval { Typist::Parser->parse($type_str) };
            if ($type && !$@) {
                my $resolved = $resolver->resolve_type_deep($type, $result->{registry});
                my $struct_name = ($resolved && $resolved->is_struct) ? $resolved->name
                                : ($resolved && $resolved->is_alias)  ? $resolved->alias_name
                                : undef;
                if ($struct_name) {
                    for my $sym (@$symbols) {
                        next unless ($sym->{kind} // '') eq 'struct' && ($sym->{name} // '') eq $struct_name;
                        return +{
                            uri  => $self->{uri},
                            line => ($sym->{line} // 1) - 1,
                            col  => ($sym->{col} // 1) - 1,
                            name => $struct_name,
                        };
                    }
                }
            }
        }
    }

    for my $sym (@$symbols) {
        next if ($sym->{kind} // '') eq 'parameter';
        next unless defined $sym->{name};
        next unless $sym->{name} eq $word || $sym->{name} eq $bare;

        my $def_line = ($sym->{line} // 1) - 1;
        $def_line = 0 if $def_line < 0;

        return +{
            uri   => $self->{uri},
            line  => $def_line,
            col   => ($sym->{col} // 1) - 1,
            name  => $sym->{name},
        };
    }

    undef;
}

# ── Function Symbol Lookup ──────────────────────

sub find_function_symbol ($self, $name) {
    my $result  = $self->{result} // return undef;
    my $symbols = $result->{symbols} // return undef;

    for my $sym (@$symbols) {
        return $sym if ($sym->{kind} // '') eq 'function' && ($sym->{name} // '') eq $name;
    }
    undef;
}

# ── Find References ─────────────────────────────

# Find all word-boundary occurrences of $name in the given lines.
# Returns arrayref of +{ line, col, len } (no uri — caller provides).
sub _find_word_occurrences ($class_or_self, $lines, $name) {
    my @hits;
    my $name_len = length($name);

    for my $i (0 .. $#$lines) {
        my $text = $lines->[$i];
        my $offset = 0;
        while ((my $pos = index($text, $name, $offset)) >= 0) {
            my $before = $pos > 0 ? substr($text, $pos - 1, 1) : '';
            my $after_pos = $pos + $name_len;
            my $after = $after_pos < length($text) ? substr($text, $after_pos, 1) : '';

            my $is_boundary = ($before eq '' || $before =~ /[^a-zA-Z0-9_]/)
                           && ($after  eq '' || $after  =~ /[^a-zA-Z0-9_]/);

            push @hits, +{ line => $i, col => $pos, len => $name_len } if $is_boundary;
            $offset = $pos + 1;
        }
    }

    \@hits;
}

# Find all occurrences of $name in this document (word-boundary matching).
# Returns arrayref of +{ uri, line, col, len }.
sub find_references ($self, $name) {
    my $hits = $self->_find_word_occurrences($self->_lines, $name);
    my $uri = $self->{uri};
    [ map { +{ %$_, uri => $uri } } @$hits ];
}

# Find scoped references for variables (sigil-prefixed names).
# Non-variable names (types, functions) return all references unchanged.
sub find_scoped_references ($self, $name, $cursor_line) {
    my $all = $self->find_references($name);

    # Only scope-filter variables
    return $all unless $name =~ /^[\$\@%]/;

    my $symbols = ($self->{result} // +{})->{symbols} // return $all;
    my $ppi_line = $cursor_line + 1;  # LSP 0-indexed → PPI 1-indexed

    # Find the scope containing the cursor
    my ($scope_start, $scope_end);
    for my $sym (@$symbols) {
        next unless ($sym->{name} // '') eq $name;
        next unless $sym->{scope_start} && $sym->{scope_end};
        if ($ppi_line >= $sym->{scope_start} && $ppi_line <= $sym->{scope_end}) {
            ($scope_start, $scope_end) = ($sym->{scope_start} - 1, $sym->{scope_end} - 1);
            last;
        }
    }
    return $all unless defined $scope_start;

    [grep { $_->{line} >= $scope_start && $_->{line} <= $scope_end } @$all];
}

# ── Inlay Hints ─────────────────────────────────

sub inlay_hints ($self, $start_line, $end_line) {
    my $result  = $self->{result} // return [];
    my $symbols = $result->{symbols} // return [];

    my @hints;
    for my $sym (@$symbols) {
        next unless ($sym->{kind} // '') eq 'variable';
        next unless $sym->{inferred};
        next if $sym->{unknown};
        next if $sym->{narrowed};

        my $line = ($sym->{line} // 1) - 1;
        next if $line < $start_line || $line > $end_line;

        my $display = _display_type($sym->{type}, $sym->{name});
        push @hints, +{
            position => +{
                line      => $line,
                character => ($sym->{col} // 1) - 1 + length($sym->{name}),
            },
            label   => ": $display",
            kind    => 1,  # Type
            tooltip => +{
                kind  => 'markdown',
                value => "```typist\n$sym->{name}: $display\n```\n*inferred*",
            },
        };
    }

    # Protocol state hints from ProtocolChecker
    for my $ph (($result->{protocol_hints} // [])->@*) {
        my $line = ($ph->{line} // 1) - 1;
        next if $line < $start_line || $line > $end_line;

        push @hints, +{
            position => +{
                line      => $line,
                character => ($ph->{col} // 1) - 1,
            },
            label   => "[" . (ref $ph->{to} ? join(' | ', $ph->{to}->@*) : $ph->{to}) . "]",
            kind    => 1,
            tooltip => +{
                kind  => 'markdown',
                value => "Protocol $ph->{label}: "
                       . (ref $ph->{from} ? join(' | ', $ph->{from}->@*) : $ph->{from})
                       . " \x{2192} "
                       . (ref $ph->{to} ? join(' | ', $ph->{to}->@*) : $ph->{to}),
            },
            paddingLeft => 1,
        };
    }

    # Inferred function return types
    for my $ifr (values(($result->{inferred_fn_returns} // +{})->%*)) {
        my $line = ($ifr->{line} // 1) - 1;
        next if $line < $start_line || $line > $end_line;

        my $name = $ifr->{name};
        my $hint_col = ($ifr->{name_col} // 1) - 1 + length($name);

        push @hints, +{
            position => +{
                line      => $line,
                character => $hint_col,
            },
            label   => " -> $ifr->{type}",
            kind    => 1,
            tooltip => +{
                kind  => 'markdown',
                value => "Inferred return type for `$name()`",
            },
            paddingLeft => \1,
        };
    }

    # Inferred effect hints for unannotated functions
    for my $ie (($result->{inferred_effects} // [])->@*) {
        my $line = ($ie->{line} // 1) - 1;
        next if $line < $start_line || $line > $end_line;

        my @labels = ($ie->{labels} // [])->@*;
        my $label_str = join(', ', @labels);
        $label_str .= ', ...' if $ie->{unknown};
        $label_str = '...' if !@labels && $ie->{unknown};

        push @hints, +{
            position => +{
                line      => $line,
                character => ($ie->{name_col} // (($ie->{col} // 1) + 4)) - 1 + length($ie->{name}),
            },
            label   => " ![$label_str]",
            kind    => 1,
            tooltip => +{
                kind  => 'markdown',
                value => "Inferred effects for `$ie->{name}()`",
            },
            paddingLeft => 1,
        };
    }

    \@hints;
}

# ── Signature Help Context ──────────────────────

sub signature_context ($self, $line, $col) {
    my $lines = $self->_lines;
    return undef unless $line < @$lines;

    # Scan backwards across lines (up to 20) for unmatched opening paren
    my $depth  = 0;
    my $commas = 0;
    my $max_lookback = 20;

    my $start_line = $line - $max_lookback < 0 ? 0 : $line - $max_lookback;
    for my $scan_line (reverse($start_line .. $line)) {
        next unless $scan_line < @$lines;
        my $text = $scan_line == $line
            ? substr($lines->[$scan_line], 0, $col)
            : $lines->[$scan_line];

        for my $i (reverse 0 .. length($text) - 1) {
            my $ch = substr($text, $i, 1);
            if ($ch eq ')') {
                $depth++;
            }
            elsif ($ch eq '(') {
                if ($depth > 0) {
                    $depth--;
                }
                else {
                    # Found unmatched opening paren
                    my $before = substr($text, 0, $i);
                    # Method call: $var->method(
                    if ($before =~ /(\$\w+)\s*->\s*(\w+)\s*\z/) {
                        return +{
                            name             => $2,
                            var              => $1,
                            is_method        => 1,
                            active_parameter => $commas,
                        };
                    }
                    return undef unless $before =~ /(\w+)\s*\z/;
                    return +{
                        name             => $1,
                        active_parameter => $commas,
                    };
                }
            }
            elsif ($ch eq ',' && $depth == 0) {
                $commas++;
            }
        }
    }

    undef;
}

# ── Document Symbols ────────────────────────────

my %SYMBOL_KIND = (
    function  => 12,  # Function
    variable  => 13,  # Variable
    typedef   => 5,   # Class (type alias)
    newtype   => 5,   # Class (nominal type)
    struct    => 23,  # Struct
    effect    => 14,  # Namespace
    typeclass => 11,  # Interface
    datatype  => 10,  # Enum (algebraic data type)
);

sub document_symbols ($self) {
    my $result  = $self->{result} // return [];
    my $symbols = $result->{symbols} // return [];

    my @out;
    for my $sym (@$symbols) {
        next if ($sym->{kind} // '') eq 'parameter';
        my $kind = $SYMBOL_KIND{$sym->{kind}} // next;

        my $line = ($sym->{line} // 1) - 1;
        $line = 0 if $line < 0;

        my $detail = $self->_symbol_detail($sym);

        push @out, +{
            name           => $sym->{name},
            kind           => $kind,
            ($detail ? (detail => $detail) : ()),
            range          => +{
                start => +{ line => $line, character => 0 },
                end   => +{ line => $line, character => 999 },
            },
            selectionRange => +{
                start => +{ line => $line, character => ($sym->{col} // 1) - 1 },
                end   => +{ line => $line, character => ($sym->{col} // 1) - 1 + length($sym->{name}) },
            },
        };
    }

    \@out;
}

sub _symbol_detail ($self, $sym) {
    my $kind = $sym->{kind};

    if ($kind eq 'function') {
        my $params = join(', ', ($sym->{params_expr} // [])->@*);
        my $detail = "($params)";
        $detail .= " -> $sym->{returns_expr}" if $sym->{returns_expr};
        return $detail;
    }

    return $sym->{type} if $kind eq 'variable' || $kind eq 'typedef'
                         || $kind eq 'newtype' || $kind eq 'datatype';

    if ($kind eq 'struct') {
        return $sym->{fields} ? join(', ', @{$sym->{fields}}) : undef;
    }

    undef;
}

# ── Code Completion Context ─────────────────────

# Detect code-level completion context at a given position.
# Returns: { kind => 'record_field', var => '$x' }
#        | { kind => 'method', prefix => '...' }
#        | { kind => 'effect_op', effect => 'Console', prefix => '...' }
#        | undef
sub code_completion_at ($self, $line, $col) {
    my $lines = $self->_lines;
    return undef unless $line < @$lines;
    return undef if $self->_is_in_comment($line, $col);
    my $text = substr($lines->[$line], 0, $col);

    # $var->{  → record field completion
    if ($text =~ /(\$\w+)\s*->\s*\{\s*(\w*)\z/) {
        return +{ kind => 'record_field', var => $1, prefix => ($2 // '') };
    }

    # match $var, ... → match arm completion
    if ($text =~ /\bmatch\s+(\$\w+)\s*,\s*(.*)\z/s) {
        my ($var, $rest) = ($1, $2);
        my @used;
        push @used, $1 while $rest =~ /(\w+)\s*=>/g;
        return +{ kind => 'match_arm', var => $var, used => \@used };
    }

    # $var->  → method completion ($self for same-package, $var for cross-package)
    if ($text =~ /(\$\w+)\s*->\s*(\w*)\z/) {
        return +{ kind => 'method', var => $1, prefix => ($2 // '') };
    }

    # Effect::  → effect operation completion
    if ($text =~ /([A-Z]\w*)::\s*(\w*)\z/) {
        return +{ kind => 'effect_op', effect => $1, prefix => ($2 // '') };
    }

    # $prefix → variable name completion
    if ($text =~ /\$(\w*)\z/) {
        return +{ kind => 'variable', prefix => $1, line => $line };
    }

    # bare word → function/constructor name completion
    if ($text =~ /(?:^|[\s({,;=])([a-zA-Z_]\w*)\z/) {
        return +{ kind => 'function', prefix => $1 };
    }

    undef;
}

# Determine completion context at a given position.
# Returns: 'type_expr' | 'generic' | 'effect' | 'constraint' | undef
sub completion_context ($self, $line, $col) {
    my $lines = $self->_lines;
    return undef unless $line < @$lines;

    my $text = substr($lines->[$line], 0, $col);

    # Inside :sig(<...>) generics — constraint context after "T: "
    return 'constraint' if $text =~ /:sig\(<[^>]*\w+\s*:\s*(?:\w+\s*\+\s*)*\z/;

    # Inside :sig(<...>) generics
    return 'generic' if $text =~ /:sig\(<[^>]*\z/;

    # Inside :sig(...) after "!" — effect context
    # Two-stage: regex match, then paren-depth check to handle nested parens
    if ($text =~ /:sig\((.*)!\s*(?:\w+\s*(?:\(\s*)?(?:\w+\s*(?:\|\s*)?)*)?(?:\)\s*)?\z/) {
        my $between = $1;
        my $depth = 0;
        my $valid = 1;
        for my $ch (split //, $between) {
            $depth++ if $ch eq '(';
            $depth-- if $ch eq ')';
            if ($depth < 0) { $valid = 0; last }
        }
        return 'effect' if $valid;
    }

    # Inside :sig(...) — paren-depth aware
    if ($text =~ /:sig\((.*)\z/) {
        my $inside = $1;
        my $depth = 0;
        my $valid = 1;
        for my $ch (split //, $inside) {
            $depth++ if $ch eq '(';
            $depth-- if $ch eq ')';
            if ($depth < 0) { $valid = 0; last }
        }
        return 'type_expr' if $valid;
    }

    # After typedef Name => or declare Name =>
    return 'type_expr' if $text =~ /typedef\s+\w+\s*=>\s*['"]?\s*\z/;
    return 'type_expr' if $text =~ /declare\s+(?:\w+|'[^']*')\s*=>\s*['"]?\s*\z/;

    undef;
}

# ── Registry Symbol Synthesis ───────────────────

sub _synthesize_function_symbol ($name, $sig) {
    my @params_expr;
    if ($sig->{params}) {
        @params_expr = map { ref $_ ? $_->to_string : $_ } @{$sig->{params}};
    }
    @params_expr = @{$sig->{params_expr}} if $sig->{params_expr} && !@params_expr;

    my $returns_expr;
    if ($sig->{returns}) {
        $returns_expr = ref $sig->{returns} ? $sig->{returns}->to_string : $sig->{returns};
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
                $g;
            } else {
                $_;
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

# Array and Hash are now first-class list types — no display rewriting needed.
sub _display_type ($type_str, $) { $type_str }

1;

__END__

=head1 NAME

Typist::LSP::Document - Per-file analysis cache and query interface

=head1 SYNOPSIS

    use Typist::LSP::Document;

    my $doc = Typist::LSP::Document->new(
        uri     => 'file:///path/to/file.pm',
        content => $source_text,
        version => 1,
    );

    $doc->analyze(workspace_registry => $registry);

    my $sym = $doc->symbol_at($line, $col);
    my $def = $doc->definition_at($line, $col);

=head1 DESCRIPTION

Typist::LSP::Document holds the content and analysis results for a single
open file. Analysis is performed lazily on first access and cached until
the content changes or the document is explicitly invalidated.

=head1 CONSTRUCTOR

=head2 new

    my $doc = Typist::LSP::Document->new(
        uri     => $uri,
        content => $text,
        version => $version,
    );

=head1 METHODS

=head2 uri

    my $uri = $doc->uri;

Returns the document URI.

=head2 content

    my $text = $doc->content;

Returns the current document content.

=head2 version

    my $ver = $doc->version;

Returns the document version number.

=head2 update

    $doc->update($new_content, $new_version);

Replace document content and clear the analysis cache.

=head2 invalidate

    $doc->invalidate;

Clear the analysis cache without changing content. Called when
workspace-level types change (e.g., after a file save).

=head2 analyze

    my $result = $doc->analyze(workspace_registry => $registry);

Run static analysis via L<Typist::Static::Analyzer>. Results are cached
until the next C<update> or C<invalidate>. Returns a hashref with
C<diagnostics>, C<symbols>, C<extracted>, and C<registry> keys.

=head2 symbol_at

    my $sym = $doc->symbol_at($line, $col);

Find the symbol at the given 0-indexed position. Searches local symbols
first, then falls back to Perl builtins and the workspace registry for
cross-package resolution.

=head2 word_at

    my $word = $doc->word_at($line, $col);

Extract the word under the cursor at the given 0-indexed position,
including sigils for variables (C<$foo>, C<@bar>).

=head2 definition_at

    my $def = $doc->definition_at($line, $col);

Look up the definition location for the symbol under the cursor.
Returns a hashref with C<uri>, C<line>, C<col>, C<name> or C<undef>.

=head2 find_function_symbol

    my $sym = $doc->find_function_symbol($name);

Find a function symbol by name in the analysis results.

=head2 find_references

    my $refs = $doc->find_references($name);

Find all word-boundary occurrences of C<$name> in this document.
Returns an arrayref of C<< +{ uri, line, col, len } >>.

=head2 inlay_hints

    my $hints = $doc->inlay_hints($start_line, $end_line);

Generate inlay hints for inferred variable types within the given
line range. Returns an arrayref of LSP InlayHint objects.

=head2 signature_context

    my $ctx = $doc->signature_context($line, $col);

Determine the signature help context at the given position.
Returns C<< +{ name => $fn_name, active_parameter => $index } >>
or C<undef> if not inside a function call.

=head2 document_symbols

    my $symbols = $doc->document_symbols;

Generate the LSP DocumentSymbol array for the document outline.

=head2 completion_context

    my $ctx = $doc->completion_context($line, $col);

Detect type annotation completion context at the given position.
Returns C<'type_expr'>, C<'generic'>, C<'effect'>, C<'constraint'>,
or C<undef>.

=head2 code_completion_at

    my $ctx = $doc->code_completion_at($line, $col);

Detect code-level completion context at the given position. Returns a
hashref describing the context kind (C<record_field>, C<method>, or
C<effect_op>) or C<undef>.

=head1 SEE ALSO

L<Typist::LSP::Server>, L<Typist::Static::Analyzer>

=cut
