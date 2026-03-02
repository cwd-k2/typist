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

sub _format ($class, $sym) {
    my $kind = $sym->{kind};

    if ($kind eq 'parameter') {
        return _code("$sym->{name}: $sym->{type}")
             . _note("parameter of `$sym->{fn_name}`");
    }

    if ($kind eq 'variable') {
        my $md = _code("$sym->{name}: $sym->{type}");
        $md .= _note('inferred') if $sym->{inferred};
        return $md;
    }

    if ($kind eq 'field') {
        return $class->_format_field($sym);
    }

    if ($kind eq 'function') {
        return $class->_format_function($sym);
    }

    if ($kind eq 'typedef') {
        return _code("type $sym->{name} = $sym->{type}");
    }

    if ($kind eq 'newtype') {
        return _code("newtype $sym->{name} = $sym->{type}");
    }

    if ($kind eq 'effect') {
        return $class->_format_effect($sym);
    }

    if ($kind eq 'typeclass') {
        return $class->_format_typeclass($sym);
    }

    if ($kind eq 'datatype') {
        return $class->_format_datatype($sym);
    }

    if ($kind eq 'struct') {
        return $class->_format_struct($sym);
    }

    undef;
}

# ── Kind-specific formatters ─────────────────────

sub _format_function ($class, $sym) {
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
    $md .= _note('declared') if $sym->{declared};
    $md;
}

sub _format_struct ($class, $sym) {
    my $fields = $sym->{fields} // [];

    # Single-line for 0-2 fields, multi-line for 3+
    if (@$fields <= 2) {
        my $body = @$fields ? ' { ' . join(', ', @$fields) . ' }' : '';
        return _code("struct $sym->{name}$body");
    }

    my $body = "struct $sym->{name} {\n";
    for my $f (@$fields) {
        $body .= "    $f,\n";
    }
    $body .= '}';
    _code($body);
}

sub _format_field ($class, $sym) {
    my $opt  = $sym->{optional} ? '?' : '';
    my $name = "$sym->{name}${opt}";
    _code("($sym->{struct_name}) $name: $sym->{type}");
}

sub _format_datatype ($class, $sym) {
    my $type = $sym->{type} // '';
    my @variants = split /\s*\|\s*/, $type;

    # Single-line for 0-2 variants, multi-line for 3+
    if (@variants <= 2) {
        my $display = "datatype $sym->{name}";
        $display .= " = $type" if $type;
        return _code($display);
    }

    my $body = "datatype $sym->{name}\n";
    for my $i (0 .. $#variants) {
        my $prefix = $i == 0 ? '    = ' : '    | ';
        $body .= "$prefix$variants[$i]\n";
    }
    chomp $body;
    _code($body);
}

sub _format_effect ($class, $sym) {
    my $op_names   = $sym->{op_names}   // [];
    my $operations = $sym->{operations} // +{};

    unless (@$op_names) {
        return _code("effect $sym->{name}");
    }

    my $body = "effect $sym->{name} {\n";
    for my $op (@$op_names) {
        my $sig = $operations->{$op} // '';
        $body .= "    $op: $sig,\n";
    }
    $body .= '}';
    _code($body);
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
        return _code($header);
    }

    my $body = "$header {\n";
    for my $m (@$method_names) {
        my $sig = $methods->{$m} // '';
        $body .= "    $m: $sig,\n";
    }
    $body .= '}';
    _code($body);
}

# ── Helpers ──────────────────────────────────────

sub _code ($text) { "```perl\n$text\n```" }

sub _note ($text) { "\n\n*$text*" }

1;
