package Typist::LSP::Document;
use v5.40;

# ── Definition Lookup & References ──────────────
#
# Go-to-definition, find-references, and scoped references.

sub definition_at ($self, $line, $col) {
    my $result  = $self->{result} // return undef;
    my $symbols = $result->{symbols} // return undef;

    my $word = $self->_word_at($line, $col) // return undef;
    return undef if $self->_is_in_comment($line, $col);
    return undef if $self->_is_in_string($line, $col);

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

1;
