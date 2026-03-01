package Typist::LSP::Document;
use v5.40;

our $VERSION = '0.01';

use Typist::Static::Analyzer;

# ── Perl Builtins ───────────────────────────────

my %BUILTINS = map { $_ => 1 } qw(
    say print printf sprintf warn die exit
    chomp chop lc uc lcfirst ucfirst length substr index rindex
    push pop shift unshift splice reverse sort
    keys values each exists delete
    map grep join split
    open close read write seek tell eof binmode truncate
    stat lstat rename unlink mkdir rmdir chdir chmod chown
    defined ref tied tie untie bless
    abs int sqrt rand srand hex oct
    chr ord pack unpack
    pos quotemeta
    scalar wantarray caller
    eval require
    sleep time alarm
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

    my $file = $self->{uri};
    $file =~ s{^file://}{};
    $file =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;

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

# Find the symbol at a given line/col (0-indexed).
sub symbol_at ($self, $line, $col) {
    my $result = $self->{result} // return undef;
    my $symbols = $result->{symbols} // return undef;

    # Primary: match by word under cursor
    if (my $word = $self->_word_at($line, $col)) {
        my $sym = $self->_find_best_symbol($symbols, $word, $line);
        return $sym if $sym;

        # Try without sigil (e.g. cursor on "foo" matches function "foo")
        (my $bare = $word) =~ s/^[\$\@%]//;
        if ($bare ne $word) {
            my $sym = $self->_find_best_symbol($symbols, $bare, $line);
            return $sym if $sym;
        }

        # Fallback: synthesize symbol for Perl builtins
        my $builtin_name = $bare // $word;
        if ($BUILTINS{$builtin_name}) {
            return +{
                name         => $builtin_name,
                kind         => 'function',
                params_expr  => ['Any...'],
                returns_expr => 'Any',
                eff_expr     => 'Eff(*)',
                builtin      => 1,
            };
        }

        # Fallback: registry lookup for cross-package or constructor symbols
        if (my $registry = $result->{registry}) {
            my $lookup_name = $bare // $word;

            if ($word =~ /::/) {
                # Qualified name: Pkg::func
                my ($pkg, $fname) = $word =~ /\A(.+)::(\w+)\z/;
                if ($pkg && $fname) {
                    if (my $sig = $registry->lookup_function($pkg, $fname)) {
                        return _synthesize_function_symbol($fname, $sig);
                    }
                }
            } else {
                # Unqualified: try current package first
                my $pkg = $result->{extracted}{package} // 'main';
                if (my $sig = $registry->lookup_function($pkg, $lookup_name)) {
                    return _synthesize_function_symbol($lookup_name, $sig);
                }

                # Then search all packages (Exporter-imported constructors, etc.)
                if (my $sig = $registry->search_function_by_name($lookup_name)) {
                    return _synthesize_function_symbol($lookup_name, $sig);
                }
            }

            # Type-level symbols: newtype, typedef, datatype, effect, typeclass
            if (my $nt = $registry->lookup_newtype($lookup_name)) {
                return +{
                    name => $lookup_name,
                    kind => 'newtype',
                    type => $nt->inner->to_string,
                };
            }
            if ($registry->has_alias($lookup_name)) {
                my $resolved = eval { $registry->lookup_type($lookup_name) };
                if ($resolved && !$resolved->is_alias) {
                    return +{
                        name => $lookup_name,
                        kind => 'typedef',
                        type => $resolved->to_string,
                    };
                }
            }
            if (my $dt = $registry->lookup_datatype($lookup_name)) {
                return +{
                    name => $lookup_name,
                    kind => 'datatype',
                    type => $dt->to_string,
                };
            }
            if (my $eff = $registry->lookup_effect($lookup_name)) {
                return +{
                    name => $lookup_name,
                    kind => 'effect',
                };
            }
            if ($registry->has_typeclass($lookup_name)) {
                return +{
                    name => $lookup_name,
                    kind => 'typeclass',
                };
            }
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

# ── Inlay Hints ─────────────────────────────────

sub inlay_hints ($self, $start_line, $end_line) {
    my $result  = $self->{result} // return [];
    my $symbols = $result->{symbols} // return [];

    my @hints;
    for my $sym (@$symbols) {
        next unless ($sym->{kind} // '') eq 'variable';
        next unless $sym->{inferred};

        my $line = ($sym->{line} // 1) - 1;
        next if $line < $start_line || $line > $end_line;

        push @hints, +{
            position => +{
                line      => $line,
                character => ($sym->{col} // 1) - 1 + length($sym->{name}),
            },
            label => ": $sym->{type}",
            kind  => 1,  # Type
        };
    }

    \@hints;
}

# ── Signature Help Context ──────────────────────

sub signature_context ($self, $line, $col) {
    my $lines = $self->_lines;
    return undef unless $line < @$lines;

    my $text = substr($lines->[$line], 0, $col);

    # Scan backwards for unmatched opening paren
    my $depth  = 0;
    my $commas = 0;
    my $paren_pos;

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
                $paren_pos = $i;
                last;
            }
        }
        elsif ($ch eq ',' && $depth == 0) {
            $commas++;
        }
    }

    return undef unless defined $paren_pos;

    # Extract function name: the word immediately before the opening paren
    my $before = substr($text, 0, $paren_pos);
    return undef unless $before =~ /(\w+)\s*\z/;

    +{
        name             => $1,
        active_parameter => $commas,
    };
}

# ── Document Symbols ────────────────────────────

my %SYMBOL_KIND = (
    function  => 12,  # Function
    variable  => 13,  # Variable
    typedef   => 5,   # Class (type alias)
    newtype   => 5,   # Class (nominal type)
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

    undef;
}

# ── Code Completion Context ─────────────────────

# Detect code-level completion context at a given position.
# Returns: { kind => 'struct_field', var => '$x' }
#        | { kind => 'method', prefix => '...' }
#        | { kind => 'effect_op', effect => 'Console', prefix => '...' }
#        | undef
sub code_completion_at ($self, $line, $col) {
    my $lines = $self->_lines;
    return undef unless $line < @$lines;
    my $text = substr($lines->[$line], 0, $col);

    # $var->{  → struct field completion
    if ($text =~ /(\$\w+)\s*->\s*\{\s*(\w*)\z/) {
        return +{ kind => 'struct_field', var => $1, prefix => ($2 // '') };
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
# Returns a type string or undef.
sub _resolve_var_type ($self, $var_name) {
    my $result = $self->{result} // return undef;
    my $symbols = $result->{symbols} // return undef;

    for my $sym (@$symbols) {
        my $kind = $sym->{kind} // '';
        next unless $kind eq 'variable' || $kind eq 'parameter';
        next unless ($sym->{name} // '') eq $var_name;
        return $sym->{type} if $sym->{type};
    }
    undef;
}

# Determine completion context at a given position.
# Returns: 'type_expr' | 'generic' | 'effect' | 'constraint' | undef
sub completion_context ($self, $line, $col) {
    my $lines = $self->_lines;
    return undef unless $line < @$lines;

    my $text = substr($lines->[$line], 0, $col);

    # Inside :Type(<...>) generics — constraint context after "T: "
    return 'constraint' if $text =~ /:Type\(<[^>]*\w+\s*:\s*(?:\w+\s*\+\s*)*\z/;

    # Inside :Type(<...>) generics
    return 'generic' if $text =~ /:Type\(<[^>]*\z/;

    # Inside :Type(...) after "!" — effect context
    return 'effect' if $text =~ /:Type\([^)]*!\s*(?:\w+\s*\|\s*)*\z/;

    # Inside :Type(...)
    return 'type_expr' if $text =~ /:Type\([^)]*\z/;

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
    };
}

1;
