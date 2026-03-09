package Typist::LSP::Hover;
use v5.40;

our $VERSION = '0.01';

# ── Public API ───────────────────────────────────

# Generate a Hover response for a symbol.
sub hover ($class, $symbol) {
    return undef unless $symbol;

    my $md = $class->_format($symbol);
    return undef unless $md;

    my $hover = +{
        contents => +{
            kind  => 'markdown',
            value => $md,
        },
    };

    $hover->{range} = $symbol->{range} if $symbol->{range};

    $hover;
}

# ── Formatting ───────────────────────────────────

my %_FORMAT_DISPATCH = (
    parameter    => sub ($class, $sym) {
        my $display = _display_type($sym->{type}, $sym->{name});
        _code("$sym->{name}: $display")
            . _note("parameter of `$sym->{fn_name}`");
    },
    variable     => sub ($class, $sym) {
        my $display = _display_type($sym->{type}, $sym->{name});
        my $md = _code("$sym->{name}: $display");
        if    ($sym->{unknown})  { $md .= _note('type unknown') }
        elsif ($sym->{narrowed}) { $md .= _note('narrowed')     }
        elsif ($sym->{inferred}) { $md .= _note('inferred')     }
        $md;
    },
    field        => sub ($class, $sym) { $class->_format_field($sym)        },
    method       => sub ($class, $sym) { $class->_format_method($sym)       },
    function     => sub ($class, $sym) { $class->_format_function($sym)     },
    typedef      => sub ($class, $sym) { _code("type $sym->{name} = $sym->{type}") . _provenance($sym)    },
    newtype      => sub ($class, $sym) { _code("newtype $sym->{name} = $sym->{type}") . _provenance($sym) },
    effect       => sub ($class, $sym) { $class->_format_effect($sym)       },
    typeclass    => sub ($class, $sym) { $class->_format_typeclass($sym)    },
    datatype     => sub ($class, $sym) { $class->_format_datatype($sym)     },
    struct       => sub ($class, $sym) { $class->_format_struct($sym)       },
    builtin_type => sub ($class, $sym) { $class->_format_builtin_type($sym) },
    match        => sub ($class, $sym) { $class->_format_match($sym)        },
    handle       => sub ($class, $sym) { $class->_format_handle($sym)       },
    scoped       => sub ($class, $sym) { $class->_format_scoped($sym)       },
);

sub _format ($class, $sym) {
    my $handler = $_FORMAT_DISPATCH{$sym->{kind}} // return undef;
    $handler->($class, $sym);
}

# ── Kind-specific formatters ─────────────────────

sub _format_function ($class, $sym) {
    return $class->_format_struct_constructor($sym) if $sym->{struct_constructor};

    my $sig = "sub $sym->{name}";

    # Generics
    if ($sym->{generics} && @{$sym->{generics}}) {
        $sig .= '<' . join(', ', @{$sym->{generics}}) . '>';
    }

    # Params
    my $params = join(', ', ($sym->{params_expr} // [])->@*);
    $sig .= "($params)";

    # Return type
    $sig .= " -> $sym->{returns_expr}" if $sym->{returns_expr};

    # Effects
    $sig .= " !$sym->{eff_expr}" if $sym->{eff_expr};

    my $md = _code($sig);
    if ($sym->{constructor}) {
        $md .= _note("constructor of `$sym->{returns_expr}`");
    } elsif ($sym->{builtin}) {
        $md .= _note($sym->{typist_builtin} ? 'Typist builtin' : 'Perl builtin');
    } elsif ($sym->{declared}) {
        $md .= _note('declared');
    } elsif ($sym->{unannotated}) {
        $md .= _note('unannotated');
    }

    # Protocol transition info for effect operations
    if ($sym->{protocol_transitions}) {
        my @lines;
        for my $t ($sym->{protocol_transitions}->@*) {
            my $from = ref $t->{from} ? join(' | ', $t->{from}->@*) : $t->{from};
            my $to   = ref $t->{to}   ? join(' | ', $t->{to}->@*)   : $t->{to};
            push @lines, "$from \x{2192} $to";
        }
        $md .= "\n\n**Protocol:** " . join(', ', @lines) if @lines;
    }

    $md;
}

sub _format_struct_constructor ($class, $sym) {
    my @fields = map { (my $f = $_) =~ s/:\s/ => /; $f } ($sym->{params_expr} // [])->@*;
    my $ret = $sym->{returns_expr} // $sym->{name};

    if (@fields <= 2) {
        my $args = @fields ? join(', ', @fields) : '';
        return _code("$sym->{name}($args) -> $ret")
             . _note("constructor of `$ret`");
    }

    my $body = "$sym->{name}(\n";
    for my $f (@fields) {
        $body .= "    $f,\n";
    }
    $body .= ") -> $ret";
    _code($body) . _note("constructor of `$ret`");
}

sub _format_struct ($class, $sym) {
    my $fields = $sym->{fields} // [];

    # Single-line for 0-2 fields, multi-line for 3+
    if (@$fields <= 2) {
        my $body = @$fields ? ' { ' . join(', ', @$fields) . ' }' : '';
        return _code("struct $sym->{name}$body") . _provenance($sym);
    }

    my $body = "struct $sym->{name} {\n";
    for my $f (@$fields) {
        $body .= "    $f,\n";
    }
    $body .= '}';
    _code($body) . _provenance($sym);
}

sub _format_match ($class, $sym) {
    my $target = $sym->{target} // '';
    _code("match($target: $sym->{type_str}) -> $sym->{result_type}");
}

sub _format_handle ($class, $sym) {
    my $effects = $sym->{effects} // [];
    return undef unless @$effects;

    my $names = join(', ', map {
        $_->{scoped} ? "$_->{var}: $_->{name}" : $_->{name}
    } @$effects);
    _code("handle: $sym->{result_type} ![$names]");
}

sub _format_scoped ($class, $sym) {
    _code("scoped '$sym->{name}' → $sym->{result_type}");
}

sub _format_builtin_type ($class, $sym) {
    my $name = $sym->{name};
    $name .= "[$sym->{params}]" if $sym->{params};
    my $md = _code("type $name") . _note('builtin');
    $md .= "\n\n$sym->{detail}" if $sym->{detail};
    $md .= "\n\n`$sym->{hierarchy}`" if $sym->{hierarchy};
    $md;
}

sub _format_field ($class, $sym) {
    my $opt  = $sym->{optional} ? '?' : '';
    my $name = "$sym->{name}${opt}";
    _code("($sym->{struct_name}) $name: $sym->{type}");
}

sub _format_method ($class, $sym) {
    _code("($sym->{struct_name}) $sym->{name}(...) -> $sym->{returns}")
    . _note("method of `$sym->{struct_name}`");
}

sub _format_datatype ($class, $sym) {
    # Prefer structured variants array when available
    my @variants;
    if ($sym->{variants} && @{$sym->{variants}}) {
        @variants = map {
            my $spec = $_->{spec};
            ($spec && $spec =~ /\S/) ? "$_->{tag}$spec" : $_->{tag};
        } $sym->{variants}->@*;
    } else {
        my $type = $sym->{type} // '';
        @variants = split /\s*\|\s*/, $type;
    }

    # Build name with type parameters: Option[T], ShopEvent[R]
    my $name = $sym->{name};
    if ($sym->{type_params} && @{$sym->{type_params}}) {
        $name .= '[' . join(', ', @{$sym->{type_params}}) . ']';
    }

    # Single-line for 0-2 variants, multi-line for 3+
    if (@variants <= 2) {
        my $display = "datatype $name";
        $display .= ' = ' . join(' | ', @variants) if @variants;
        return _code($display) . _provenance($sym);
    }

    my $body = "datatype $name\n";
    for my $i (0 .. $#variants) {
        my $prefix = $i == 0 ? '    = ' : '    | ';
        $body .= "$prefix$variants[$i]\n";
    }
    chomp $body;
    _code($body) . _provenance($sym);
}

sub _format_effect ($class, $sym) {
    my $op_names   = $sym->{op_names}   // [];
    my $operations = $sym->{operations} // +{};
    my $protocol   = $sym->{protocol};

    unless (@$op_names) {
        return _code("effect $sym->{name}");
    }

    # Build reverse lookup: op → [from → to] for inline display
    my %op_transitions;
    if ($protocol && ref $protocol eq 'HASH') {
        for my $state (keys %$protocol) {
            my $ops = $protocol->{$state};
            for my $op (keys %$ops) {
                push $op_transitions{$op}->@*, "$state \x{2192} $ops->{$op}";
            }
        }
    }

    # Collect states for header
    my $states_str = '';
    if ($sym->{states} && ref $sym->{states} eq 'ARRAY' && $sym->{states}->@*) {
        $states_str = ' [' . join(', ', $sym->{states}->@*) . ']';
    } elsif ($protocol && ref $protocol eq 'HASH') {
        # Derive from transitions
        my %seen;
        for my $from (keys %$protocol) {
            $seen{$from} = 1;
            $seen{$_} = 1 for values $protocol->{$from}->%*;
        }
        $states_str = ' [' . join(', ', sort keys %seen) . ']' if %seen;
    }

    my $body = "effect $sym->{name}${states_str} {\n";
    for my $op (@$op_names) {
        my $sig = $operations->{$op} // '';
        my $transition = '';
        if ($op_transitions{$op}) {
            $transition = '  [' . join(', ', sort $op_transitions{$op}->@*) . ']';
        }
        $body .= "    $op: $sig${transition},\n";
    }
    $body .= '}';

    _code($body) . _provenance($sym);
}

sub _format_typeclass ($class, $sym) {
    my $method_names = $sym->{method_names} // [];
    my $methods      = $sym->{methods}      // +{};
    my $var_spec     = $sym->{var_spec};

    my $header = "typeclass $sym->{name}";
    $header .= "<$var_spec>" if $var_spec;

    # No methods or no signatures: compact form
    unless (@$method_names && %$methods) {
        if (@$method_names) {
            $header .= ' { ' . join(', ', @$method_names) . ' }';
        }
        return _code($header) . _provenance($sym);
    }

    my $body = "$header {\n";
    for my $m (@$method_names) {
        my $sig = $methods->{$m} // '';
        $body .= "    $m: $sig,\n";
    }
    $body .= '}';
    _code($body) . _provenance($sym);
}

# ── Helpers ──────────────────────────────────────

sub _code ($text) { "```typist\n$text\n```" }

sub _note ($text) { "\n\n*$text*" }
sub _provenance ($sym) { $sym->{defined_in} ? _note("defined in `$sym->{defined_in}`") : '' }

# Array and Hash are now first-class list types — no display rewriting needed.
sub _display_type ($type_str, $) { $type_str }

1;

__END__

=head1 NAME

Typist::LSP::Hover - Hover tooltip formatter for the Typist LSP server

=head1 DESCRIPTION

Generates LSP Hover responses from symbol information hashes produced
by L<Typist::LSP::Document>.  Each symbol kind (function, variable,
parameter, typedef, newtype, datatype, struct, effect, typeclass, field,
method) is rendered as a fenced Markdown code block with Typist syntax.

=head2 hover

    my $hover = Typist::LSP::Hover->hover($symbol);

Returns an LSP Hover response hashref for the given C<$symbol>, or
C<undef> if the symbol is unknown or cannot be formatted.  The response
contains a C<contents> field with C<kind =E<gt> 'markdown'> and an
optional C<range> when the symbol provides positional information.

=cut
