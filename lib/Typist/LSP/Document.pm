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

    # Expand left from $col
    my $start = $col;
    while ($start > 0 && substr($text, $start - 1, 1) =~ /[\w\$\@%]/) {
        $start--;
    }

    # Expand right from $col
    my $end = $col;
    while ($end < $len && substr($text, $end, 1) =~ /\w/) {
        $end++;
    }

    return undef if $start == $end;

    my $word = substr($text, $start, $end - $start);
    # Strip leading sigil noise if it's just a bare sigil
    return undef if $word =~ /^[\$\@%]$/;

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

    # After typedef Name =>
    return 'type_expr' if $text =~ /typedef\s+\w+\s*=>\s*['"]?\s*\z/;

    undef;
}

1;
