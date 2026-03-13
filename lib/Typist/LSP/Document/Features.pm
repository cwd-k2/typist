package Typist::LSP::Document;
use v5.40;

# ── LSP Features ────────────────────────────────
#
# Inlay hints, signature help, document symbols, and completion context.

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
        # Skip bare type variables (A, T, _) — no useful information
        next if ($sym->{type} // '') =~ /\A[A-Z_]\z/;

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
                    # Qualified call: Package::func(
                    if ($before =~ /(\w+)::(\w+)\s*\z/) {
                        return +{
                            name             => $2,
                            qualifier        => $1,
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
    return undef if $self->_is_in_string($line, $col);
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

1;
