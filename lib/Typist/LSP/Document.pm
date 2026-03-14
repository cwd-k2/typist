package Typist::LSP::Document;
use v5.40;

our $VERSION = '0.01';

use Typist::Static::Analyzer;
use Typist::Parser;
use Typist::Prelude;
use Typist::LSP::Transport;
use Typist::LSP::Document::Resolver;
use Typist::Static::SymbolInfo qw(
    sym_function sym_variable sym_typedef sym_newtype
    sym_effect sym_typeclass sym_datatype sym_struct sym_field sym_method
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
sub result  ($self) { $self->{result} }

sub update ($self, $content, $version) {
    $self->{content}   = $content;
    $self->{version}   = $version;
    $self->{result}    = undef;
    $self->{extracted} = undef;  # content changed — must re-extract
    $self->{lines}     = undef;
}

sub _resolver ($self) {
    Typist::LSP::Document::Resolver->new(
        result => $self->{result},
        lines  => $self->_lines,
    );
}

# Delegate methods for external callers (Completion, Server)
sub resolve_var_type ($self, $var_name, $line = undef) {
    $self->_resolver->resolve_var_type($var_name, $line);
}

sub resolve_type_deep ($self, $type, $registry) {
    $self->_resolver->resolve_type_deep($type, $registry);
}

# Invalidate cached analysis without changing content (e.g., workspace registry changed).
sub invalidate ($self) {
    $self->{result} = undef;
}

# ── Analysis ─────────────────────────────────────

sub analyze ($self, %opts) {
    return $self->{result} if $self->{result};

    my $file = Typist::LSP::Transport::uri_to_path($self->{uri});

    # Reuse cached extracted data when only the registry changed (invalidate),
    # skipping PPI re-parse (~40-60% of analysis cost).
    my $extracted = $opts{extracted} // $self->{extracted};

    $self->{result} = eval {
        Typist::Static::Analyzer->analyze(
            $self->{content},
            file               => $file,
            workspace_registry => $opts{workspace_registry},
            ($extracted           ? (extracted      => $extracted)             : ()),
            ($opts{gradual_hints} ? (gradual_hints  => $opts{gradual_hints})  : ()),
        );
    };

    # Analysis failed (e.g., PPI cannot parse non-Perl content).
    # Cache a minimal empty result so subsequent requests short-circuit
    # instead of retrying and failing on every hover/completion.
    if ($@ && !$self->{result}) {
        warn "Typist::LSP::Document: analysis failed: $@";
    }
    unless ($self->{result}) {
        $self->{result} = +{
            errors    => [],
            symbols   => [],
            extracted => +{ package => 'main', functions => +{} },
        };
        return $self->{result};
    }

    # Cache extracted for potential reuse on invalidate()
    $self->{extracted} //= $self->{result}{extracted};

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
    my $result = $self->_word_range_at($line, $col) // return undef;
    $result->{word};
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

    # Handle cursor positioned on sigil ($, @, %)
    if ($start == $end && $col < $len && substr($text, $col, 1) =~ /[\$\@%]/) {
        $end = $col + 1;
        while ($end < $len && substr($text, $end, 1) =~ /\w/) {
            $end++;
        }
        $start = $col;
    }

    return undef if $start == $end;

    my $word = substr($text, $start, $end - $start);
    return undef if $word =~ /^[\$\@%]$/;
    return undef if $word eq '::';

    +{ word => $word, start => $start, end => $end };
}

# Check if the cursor position falls within a PPI comment or pod token.
sub _is_in_comment ($self, $line, $col) {
    my $ppi_doc = ($self->{result} // return 0)->{extracted}{ppi_doc} // return 0;
    my $ppi_line = $line + 1;  # LSP 0-indexed → PPI 1-indexed
    my $comments = $ppi_doc->find('PPI::Token::Comment') || [];
    for my $t (@$comments) {
        next unless $t->line_number == $ppi_line;
        return 1 if $col >= $t->column_number - 1;  # PPI 1-indexed → 0-indexed
    }
    my $pods = $ppi_doc->find('PPI::Token::Pod') || [];
    for my $t (@$pods) {
        my $start_line = $t->line_number;
        my $end_line = $start_line + (() = $t->content =~ /\n/g);
        return 1 if $ppi_line >= $start_line && $ppi_line <= $end_line;
    }
    0;
}

# Check if the cursor position falls within a PPI string token (Quote/HereDoc).
# Exception: strings inside Typist declarations (typedef, struct, effect, etc.)
# contain type expressions and should NOT be suppressed.
sub _is_in_string ($self, $line, $col) {
    my $ppi_doc = ($self->{result} // return 0)->{extracted}{ppi_doc} // return 0;
    my $ppi_line = $line + 1;  # LSP 0-indexed → PPI 1-indexed

    my $strings = $ppi_doc->find(sub {
        $_[1]->isa('PPI::Token::Quote') || $_[1]->isa('PPI::Token::HereDoc')
    }) || [];

    for my $t (@$strings) {
        if ($t->isa('PPI::Token::HereDoc')) {
            my @body = $t->heredoc;
            next unless @body;
            my $body_start = $t->line_number + 1;
            my $body_end   = $body_start + $#body;
            if ($ppi_line >= $body_start && $ppi_line <= $body_end) {
                return 0 if _in_typist_declaration($t);
                return 1;
            }
            next;
        }

        my $start_line = $t->line_number;
        my $start_col  = $t->column_number - 1;  # PPI 1-indexed → 0-indexed
        my $content    = $t->content;
        my $newlines   = () = $content =~ /\n/g;
        my $end_line   = $start_line + $newlines;

        next if $ppi_line < $start_line || $ppi_line > $end_line;

        my $inside = $start_line == $end_line
            ? ($col >= $start_col && $col < $start_col + length($content))
            : $ppi_line == $start_line ? ($col >= $start_col)
            : $ppi_line == $end_line   ? ($col < length($content) - rindex($content, "\n") - 1)
            :                            1;  # middle line

        if ($inside) {
            return 0 if _in_typist_declaration($t);
            return 1;
        }
    }
    0;
}

# Check if a PPI token is inside a Typist declaration statement
# (typedef, newtype, struct, effect, typeclass, instance, datatype, enum, declare, protocol).
my %_TYPIST_DECL_KW = map { $_ => 1 } qw(
    typedef newtype struct effect typeclass instance datatype enum declare protocol
);
sub _in_typist_declaration ($token) {
    my $node = $token;
    while ($node = $node->parent) {
        next unless $node->isa('PPI::Statement');
        next if $node->isa('PPI::Statement::Expression');
        my $first = $node->schild(0) or return 0;
        return 0 unless $first->isa('PPI::Token::Word');
        return $_TYPIST_DECL_KW{$first->content} // 0;
    }
    0;
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

# ── Public word accessor ─────────────────────────

sub word_at ($self, $line, $col) { $self->_word_at($line, $col) }

# ── Cross-partial utilities ──────────────────────

# Array and Hash are now first-class list types — no display rewriting needed.
sub _display_type ($type_str, $) { $type_str }

# ── Sub-modules (partial-package pattern) ────────

require Typist::LSP::Document::Hover;
require Typist::LSP::Document::Navigation;
require Typist::LSP::Document::Features;

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
