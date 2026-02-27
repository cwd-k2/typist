package Typist::LSP::Document;
use v5.40;

use Typist::Static::Analyzer;

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

# ── Analysis ─────────────────────────────────────

sub analyze ($self, %opts) {
    return $self->{result} if $self->{result};

    my $file = $self->{uri};
    $file =~ s{^file://}{};

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

# Find the symbol at a given line/col (0-indexed).
sub symbol_at ($self, $line, $col) {
    my $result = $self->{result} // return undef;
    my $symbols = $result->{symbols} // return undef;

    # Find the best matching symbol at or near this line
    my $best;
    for my $sym (@$symbols) {
        next unless defined $sym->{line};
        # Symbols are 1-indexed from PPI; LSP positions are 0-indexed
        my $sym_line = $sym->{line} - 1;
        if ($sym_line == $line) {
            $best = $sym;
            last;
        }
        # Take the closest symbol above the cursor
        if ($sym_line <= $line) {
            $best = $sym unless $best && ($line - ($best->{line} - 1)) < ($line - $sym_line);
        }
    }

    $best;
}

# Determine completion context at a given position.
# Returns: 'type_expr' | 'generic' | undef
sub completion_context ($self, $line, $col) {
    my $lines = $self->_lines;
    return undef unless $line < @$lines;

    my $text = substr($lines->[$line], 0, $col);

    # Inside :Generic(...)
    return 'generic' if $text =~ /:Generic\([^)]*\z/;

    # Inside :Type(...), :Params(...), :Returns(...)
    return 'type_expr' if $text =~ /:(?:Type|Params|Returns)\([^)]*\z/;

    # After typedef Name =>
    return 'type_expr' if $text =~ /typedef\s+\w+\s*=>\s*['"]?\s*\z/;

    undef;
}

1;
