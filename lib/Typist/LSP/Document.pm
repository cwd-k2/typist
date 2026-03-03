package Typist::LSP::Document;
use v5.40;

our $VERSION = '0.01';

use Typist::Static::Analyzer;
use Typist::Parser;
use Typist::Prelude;
use Typist::LSP::Transport;

# ── Perl Builtins ───────────────────────────────

my %BUILTINS = map { $_ => 1 } Typist::Prelude->builtin_names;

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
    $self->{content} = $content;
    $self->{version} = $version;
    $self->{result}  = undef;
    $self->{lines}   = undef;
}

# Invalidate cached analysis without changing content (e.g., workspace registry changed).
sub invalidate ($self) {
    $self->{result} = undef;
}

# ── Analysis ─────────────────────────────────────

sub analyze ($self, %opts) {
    return $self->{result} if $self->{result};

    my $file = Typist::LSP::Transport::uri_to_path($self->{uri});

    $self->{result} = Typist::Static::Analyzer->analyze(
        $self->{content},
        file               => $file,
        workspace_registry => $opts{workspace_registry},
    );

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

    return undef if $start == $end;

    my $word = substr($text, $start, $end - $start);
    return undef if $word =~ /^[\$\@%]$/;
    return undef if $word eq '::';

    +{ word => $word, start => $start, end => $end };
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
    if (my $field_sym = $self->_resolve_accessor_hover($line, $col, $word)) {
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

    # Fallback: synthesize symbol for Perl builtins
    # Skip builtin resolution for hash keys (word followed by =>)
    my $builtin_name = $bare // $word;
    my $is_hash_key = do {
        my $text = $self->_lines->[$line] // '';
        $wr->{end} < length($text)
            && substr($text, $wr->{end}) =~ /\A\s*=>/;
    };
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
        return $with_range->(+{
            name         => $builtin_name,
            kind         => 'function',
            params_expr  => ['Any...'],
            returns_expr => 'Any',
            eff_expr     => '[*]',
            builtin      => 1,
            (Typist::Prelude->is_typist_builtin($builtin_name) ? (typist_builtin => 1) : ()),
        });
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
        if (my $nt = $registry->lookup_newtype($lookup_name)) {
            return $with_range->(+{
                name => $lookup_name,
                kind => 'newtype',
                type => $nt->inner->to_string,
            });
        }
        if ($registry->has_alias($lookup_name)) {
            my $resolved = $registry->lookup_type($lookup_name);
            if ($resolved) {
                return $with_range->(+{
                    name => $lookup_name,
                    kind => 'typedef',
                    type => $resolved->to_string,
                });
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
            return $with_range->(+{
                name        => $lookup_name,
                kind        => 'datatype',
                type        => $dt->to_string,
                type_params => \@tp,
                variants    => \@variants,
            });
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
            return $with_range->(+{
                name   => $lookup_name,
                kind   => 'struct',
                fields => \@field_descs,
            });
        }
        if (my $eff = $registry->lookup_effect($lookup_name)) {
            my @op_names;
            my %operations;
            for my $op_name (sort keys %{$eff->ops // +{}}) {
                push @op_names, $op_name;
                my $op_type = $eff->get_op_type($op_name);
                $operations{$op_name} = $op_type ? $op_type->to_string : $eff->ops->{$op_name};
            }
            return $with_range->(+{
                name       => $lookup_name,
                kind       => 'effect',
                op_names   => \@op_names,
                operations => \%operations,
            });
        }
        if ($registry->has_typeclass($lookup_name)) {
            my $tc = $registry->lookup_typeclass($lookup_name);
            my @method_names;
            my %methods;
            if ($tc) {
                @method_names = sort keys %{$tc->methods // +{}};
                for my $m (@method_names) {
                    $methods{$m} = $tc->methods->{$m};
                }
            }
            return $with_range->(+{
                name         => $lookup_name,
                kind         => 'typeclass',
                var_spec     => $tc ? $tc->var_name : undef,
                method_names => \@method_names,
                methods      => \%methods,
            });
        }
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

    # Prefer scoped symbol (parameter) when cursor is within its scope
    for my $sym (@candidates) {
        if ($sym->{scope_start} && $sym->{scope_end}) {
            return $sym if $ppi_line >= $sym->{scope_start}
                        && $ppi_line <= $sym->{scope_end};
        }
    }

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

    # Strip sigil for type/function lookup
    (my $bare = $word) =~ s/^[\$\@%]//;

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
            label   => "[$ph->{to}]",
            kind    => 1,
            tooltip => +{
                kind  => 'markdown',
                value => "Protocol $ph->{label}: $ph->{from} \x{2192} $ph->{to}",
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
    my $text = substr($lines->[$line], 0, $col);

    # $var->{  → record field completion
    if ($text =~ /(\$\w+)\s*->\s*\{\s*(\w*)\z/) {
        return +{ kind => 'record_field', var => $1, prefix => ($2 // '') };
    }

    # $self->  → method completion (only $self, not arbitrary variables)
    if ($text =~ /\$self\s*->\s*(\w*)\z/) {
        return +{ kind => 'method', prefix => ($1 // '') };
    }

    # Effect::  → effect operation completion
    if ($text =~ /([A-Z]\w*)::\s*(\w*)\z/) {
        return +{ kind => 'effect_op', effect => $1, prefix => ($2 // '') };
    }

    undef;
}

# Resolve the type of a variable from analysis symbols.
# When $line (0-indexed LSP line) is given, prefer scoped symbols that
# contain the line and skip Any-typed entries when a better match exists.
sub _resolve_var_type ($self, $var_name, $line = undef) {
    my $result = $self->{result} // return undef;
    my $symbols = $result->{symbols} // return undef;

    my $ppi_line = defined $line ? $line + 1 : undef;  # LSP 0-indexed → PPI 1-indexed
    my ($best, $best_any);

    for my $sym (@$symbols) {
        my $kind = $sym->{kind} // '';
        next unless $kind eq 'variable' || $kind eq 'parameter';
        next unless ($sym->{name} // '') eq $var_name;
        next unless $sym->{type};

        my $is_any = $sym->{type} eq 'Any';

        # Scoped symbol: check if hover line falls within scope
        if ($ppi_line && $sym->{scope_start} && $sym->{scope_end}) {
            if ($ppi_line >= $sym->{scope_start} && $ppi_line <= $sym->{scope_end}) {
                return $sym->{type} unless $is_any;
                $best_any //= $sym->{type};
                next;
            }
            next;  # out of scope — skip
        }

        # Non-scoped symbol
        if ($is_any) {
            $best_any //= $sym->{type};
        } else {
            $best //= $sym->{type};
        }
    }

    $best // $best_any;
}

# Resolve struct field type for accessor hover.
# Supports: $var->field, $var->f1->f2, func()->field, Pkg::func()->field
# Returns a symbol hashref with kind => 'field' or undef.
sub _resolve_accessor_hover ($self, $line, $col, $word) {
    my $lines = $self->_lines;
    return undef unless $line < @$lines;

    my $result   = $self->{result} // return undef;
    my $registry = $result->{registry} // return undef;

    # Find the end of the word under cursor (skip past $col to end of \w chars)
    my $full_line = $lines->[$line];
    my $word_end = $col;
    $word_end++ while $word_end < length($full_line) && substr($full_line, $word_end, 1) =~ /\w/;
    my $text = substr($full_line, 0, $word_end);

    # Must contain -> to be an accessor
    return undef unless $text =~ /->/;

    # Extract the accessor chain suffix: ->field1->field2...
    return undef unless $text =~ /((?:\s*->\s*\w+)+)\s*$/;
    my $chain_str = $1;
    my @chain = ($chain_str =~ /->\s*(\w+)/g);
    return undef unless @chain && $chain[-1] eq $word;

    my $prefix = substr($text, 0, length($text) - length($chain_str));

    # Try resolving the head type from prefix
    my $type_str;

    # Pattern 1: $var->...
    if ($prefix =~ /(\$\w+)\s*$/) {
        $type_str = $self->_resolve_var_type($1, $line);
    }

    # Pattern 2: func(...)->... or Pkg::func(...)->...
    if (!$type_str && $prefix =~ /\)\s*$/) {
        $type_str = $self->_resolve_call_return_type($prefix, $registry);
    }

    return undef unless $type_str;
    my $type = eval { Typist::Parser->parse($type_str) } // return undef;

    # Check if this accessor is narrowed by defined() guard
    my $narrowed = 0;
    my $ppi_line = $line + 1;  # LSP 0-indexed → PPI 1-indexed
    for my $na (($result->{narrowed_accessors} // [])->@*) {
        next unless $na->{var_name} eq ($prefix =~ /(\$\w+)\s*$/ ? $1 : '');
        next unless $ppi_line >= $na->{scope_start} && $ppi_line <= $na->{scope_end};
        # Compare chains: narrowed chain must match the accessor chain
        my $nc = $na->{chain};
        next unless @$nc == @chain;
        my $match = 1;
        for my $i (0 .. $#chain) {
            if ($nc->[$i] ne $chain[$i]) { $match = 0; last }
        }
        if ($match) { $narrowed = 1; last }
    }

    $self->_walk_accessor_chain($type, \@chain, $word, $registry, $narrowed);
}

# Walk an accessor chain, resolving struct fields and newtype ->base at each step.
sub _walk_accessor_chain ($self, $type, $chain, $word, $registry, $narrowed = 0) {
    for my $i (0 .. $#$chain) {
        my $field = $chain->[$i];

        # Resolve alias → concrete type (newtype, struct, or datatype)
        my $resolved = $self->_resolve_type_deep($type, $registry) // return undef;

        # Newtype: only ->base is valid
        if ($resolved->is_newtype) {
            return undef unless $field eq 'base';
            $type = $resolved->inner;
            if ($i == $#$chain) {
                return +{
                    kind     => 'variable',
                    name     => 'base',
                    type     => $type->to_string,
                    inferred => 1,
                };
            }
            next;
        }

        # Struct: field accessor
        my $struct = $resolved->is_struct ? $resolved
                   : $self->_resolve_to_struct($resolved, $registry) // return undef;

        my %req = $struct->required_fields;
        my %opt = $struct->optional_fields;

        if (exists $req{$field}) {
            $type = $req{$field};
            if ($i == $#$chain) {
                return +{
                    kind        => 'field',
                    name        => $field,
                    type        => $type->to_string,
                    struct_name => $struct->name,
                    optional    => 0,
                };
            }
        } elsif (exists $opt{$field}) {
            $type = $opt{$field};
            if ($i == $#$chain) {
                return +{
                    kind        => 'field',
                    name        => $field,
                    type        => $type->to_string,
                    struct_name => $struct->name,
                    optional    => $narrowed ? 0 : 1,
                };
            }
        } elsif ($field eq 'with') {
            $type = $resolved;
            if ($i == $#$chain) {
                return +{
                    kind        => 'method',
                    name        => 'with',
                    struct_name => $struct->name,
                    returns     => $resolved->to_string,
                };
            }
        } else {
            return undef;
        }
    }
    undef;
}

# Resolve a type through aliases to its concrete form (newtype, struct, datatype, etc.).
sub _resolve_type_deep ($self, $type, $registry) {
    return $type if $type->is_newtype || $type->is_struct;
    if ($type->is_alias) {
        my $resolved = eval { $registry->lookup_type($type->alias_name) };
        return $resolved if $resolved;
    }
    $type;
}

# Resolve the return type of a function call from a text prefix ending with ')'.
# Handles: func(...), Pkg::func(...), nested parens.
sub _resolve_call_return_type ($self, $prefix, $registry) {
    # Find the matching '(' by scanning backwards from the last ')'
    my $depth = 0;
    my $paren_pos;
    for my $i (reverse 0 .. length($prefix) - 1) {
        my $ch = substr($prefix, $i, 1);
        if ($ch eq ')') {
            $depth++;
        } elsif ($ch eq '(') {
            $depth--;
            if ($depth == 0) {
                $paren_pos = $i;
                last;
            }
        }
    }
    return undef unless defined $paren_pos;

    # Extract function name before the '('
    my $before = substr($prefix, 0, $paren_pos);
    return undef unless $before =~ /((?:\w+::)*\w+)\s*$/;
    my $func_name = $1;

    $self->_resolve_func_return_type($func_name, $registry);
}

# Look up function return type from local symbols and registry.
sub _resolve_func_return_type ($self, $func_name, $registry) {
    my $result = $self->{result} // return undef;

    # Local symbols
    for my $sym (@{$result->{symbols} // []}) {
        next unless ($sym->{kind} // '') eq 'function';
        next unless ($sym->{name} // '') eq $func_name;
        return $sym->{returns_expr} if $sym->{returns_expr};
    }

    return undef unless $registry;

    # Qualified name: Pkg::func
    if ($func_name =~ /\A(.+)::(\w+)\z/) {
        if (my $sig = $registry->lookup_function($1, $2)) {
            return _sig_returns_str($sig);
        }
    }

    # Current package
    my $pkg = $result->{extracted}{package} // 'main';
    if (my $sig = $registry->lookup_function($pkg, $func_name)) {
        return _sig_returns_str($sig);
    }

    # Search all packages (Exporter-imported constructors, etc.)
    if (my $sig = $registry->search_function_by_name($func_name)) {
        return _sig_returns_str($sig);
    }

    undef;
}

sub _sig_returns_str ($sig) {
    if ($sig->{returns}) {
        return ref $sig->{returns} ? $sig->{returns}->to_string : $sig->{returns};
    }
    $sig->{returns_expr};
}

# Resolve a type to a Struct via alias/registry lookup.
sub _resolve_to_struct ($self, $type, $registry) {
    return $type if $type->is_struct;
    if ($type->is_alias) {
        my $resolved = eval { $registry->lookup_type($type->alias_name) };
        return $resolved if $resolved && $resolved->is_struct;
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
        @generics = map { ref $_ eq 'HASH' ? $_->{name} : $_ } @{$sig->{generics}};
    }

    my $eff_expr;
    if ($sig->{effects}) {
        $eff_expr = ref $sig->{effects} ? $sig->{effects}->to_string : $sig->{effects};
    }

    +{
        name         => $name,
        kind         => 'function',
        params_expr  => \@params_expr,
        returns_expr => $returns_expr,
        generics     => \@generics,
        eff_expr     => $eff_expr,
        ($sig->{constructor} ? (constructor => 1) : ()),
    };
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
