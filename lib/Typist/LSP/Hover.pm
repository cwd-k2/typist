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
        return "```perl\nsub $sym->{name}($sym->{type})\n```";
    }

    if ($kind eq 'typedef') {
        return "```perl\ntype $sym->{name} = $sym->{type}\n```";
    }

    undef;
}

1;
