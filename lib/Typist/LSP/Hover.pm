package Typist::LSP::Hover;
use v5.40;

# ── Public API ───────────────────────────────────

# Generate a Hover response for a symbol.
sub hover ($class, $symbol) {
    return undef unless $symbol;

    my $md = $class->_format($symbol);
    return undef unless $md;

    +{
        contents => +{
            kind  => 'markdown',
            value => $md,
        },
    };
}

# ── Formatting ───────────────────────────────────

sub _format ($class, $sym) {
    my $kind = $sym->{kind};

    if ($kind eq 'variable') {
        return "```perl\n$sym->{name}: $sym->{type}\n```";
    }

    if ($kind eq 'function') {
        my $sig = "sub $sym->{name}";

        # Generics
        if ($sym->{generics} && @{$sym->{generics}}) {
            $sig .= '<' . join(', ', @{$sym->{generics}}) . '>';
        }

        $sig .= "($sym->{type})";

        # Effects
        if ($sym->{eff_expr}) {
            $sig .= " !Eff($sym->{eff_expr})";
        }

        return "```perl\n$sig\n```";
    }

    if ($kind eq 'typedef') {
        return "```perl\ntype $sym->{name} = $sym->{type}\n```";
    }

    if ($kind eq 'newtype') {
        return "```perl\nnewtype $sym->{name} = $sym->{type}\n```";
    }

    if ($kind eq 'effect') {
        return "```perl\neffect $sym->{name}\n```";
    }

    if ($kind eq 'typeclass') {
        my $display = "typeclass $sym->{name}";
        if ($sym->{var_spec}) {
            $display .= "<$sym->{var_spec}>";
        }
        if ($sym->{method_names} && @{$sym->{method_names}}) {
            $display .= ' { ' . join(', ', @{$sym->{method_names}}) . ' }';
        }
        return "```perl\n$display\n```";
    }

    undef;
}

1;
