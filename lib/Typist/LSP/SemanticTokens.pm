package Typist::LSP::SemanticTokens;
use v5.40;

our $VERSION = '0.01';

# ── Token Type / Modifier Legend ─────────────────

my @TOKEN_TYPES = qw(
    type
    typeParameter
    variable
    function
    keyword
    class
    enum
    enumMember
    operator
    number
    string
);

my @TOKEN_MODIFIERS = qw(
    declaration
    definition
    readonly
);

# Build index maps for encoding
my %TYPE_INDEX;
$TYPE_INDEX{$TOKEN_TYPES[$_]} = $_ for 0 .. $#TOKEN_TYPES;

my %MOD_BIT;
$MOD_BIT{$TOKEN_MODIFIERS[$_]} = 1 << $_ for 0 .. $#TOKEN_MODIFIERS;

# ── Typist keyword set (PPI-based scan) ──────────
my @TYPIST_KEYWORDS = qw(
    typedef newtype effect typeclass instance
    datatype enum struct declare
    handle match protocol sub
);
my %TYPIST_KEYWORD_SET = map { $_ => 1 } @TYPIST_KEYWORDS;

# ── Public API ───────────────────────────────────

# Returns the LSP semantic tokens legend.
sub legend ($class) {
    +{
        tokenTypes    => \@TOKEN_TYPES,
        tokenModifiers => \@TOKEN_MODIFIERS,
    };
}

# Compute semantic tokens for an analyzed document.
# Returns a hashref with a `data` key containing the delta-encoded integer array.
sub compute ($class, $doc) {
    my $result = $doc->result // return +{ data => [] };
    my $extracted = $result->{extracted} // return +{ data => [] };
    my @lines = $doc->lines->@*;

    my @tokens;

    # ── typedef declarations ──────────────────
    for my $name (keys $extracted->{aliases}->%*) {
        my $info = $extracted->{aliases}{$name};
        my $line0 = ($info->{line} // 1) - 1;
        _scan_defined_name(\@tokens, \@lines, $line0, $name, 'type');
        _tokenize_quoted_types(\@tokens, \@lines, $line0, +{}, 0);
    }

    # ── newtype declarations ──────────────────
    for my $name (keys $extracted->{newtypes}->%*) {
        my $info = $extracted->{newtypes}{$name};
        my $line0 = ($info->{line} // 1) - 1;
        _scan_defined_name(\@tokens, \@lines, $line0, $name, 'type');
    }

    # ── effect declarations ───────────────────
    for my $name (keys $extracted->{effects}->%*) {
        my $info = $extracted->{effects}{$name};
        my $line0 = ($info->{line} // 1) - 1;
        _scan_defined_name(\@tokens, \@lines, $line0, $name, 'enum');
        _tokenize_sig_strings(\@tokens, \@lines, $line0, $info->{operations} // +{});
    }

    # ── typeclass declarations ────────────────
    for my $name (keys $extracted->{typeclasses}->%*) {
        my $info = $extracted->{typeclasses}{$name};
        my $line0 = ($info->{line} // 1) - 1;
        _scan_defined_name(\@tokens, \@lines, $line0, $name, 'class');

        my $var = $info->{var_spec} // '';
        $var =~ s/\s*:.*\z//;
        my %generics = length($var) ? ($var => 1) : ();
        _tokenize_sig_strings(\@tokens, \@lines, $line0, $info->{methods} // +{}, \%generics);
    }

    # ── datatype declarations ─────────────────
    for my $name (keys(($extracted->{datatypes} // +{})->%*)) {
        my $info = $extracted->{datatypes}{$name};
        my $line0 = ($info->{line} // 1) - 1;

        _scan_defined_name(\@tokens, \@lines, $line0, $name, 'type');

        # Variant / enum member tokens
        my $variants = $info->{variants} // +{};
        for my $tag (keys %$variants) {
            # Variants may appear on any line from line0 onward
            for my $li ($line0 .. $#lines) {
                my $pos = _word_pos($lines[$li], $tag);
                if (defined $pos) {
                    push @tokens, [$li, $pos, length($tag), 'enumMember', 0];
                    last;
                }
            }
        }

        # Type names inside variant specs: '(Int)', '(Int, Int)', '(T)'
        my %tp = map { $_ => 1 } @{$info->{type_params} // []};
        _tokenize_quoted_types(\@tokens, \@lines, $line0, \%tp);
    }

    # ── struct declarations ───────────────────
    for my $name (keys(($extracted->{structs} // +{})->%*)) {
        my $info = $extracted->{structs}{$name};
        my $line0 = ($info->{line} // 1) - 1;
        _scan_defined_name(\@tokens, \@lines, $line0, $name, 'type');

        # Field name tokens with readonly modifier
        my $fields = $info->{fields} // +{};
        for my $field_name (keys %$fields) {
            # Fields appear in the struct definition, potentially across lines
            my $end = ($line0 + 10 < $#lines) ? $line0 + 10 : $#lines;
            for my $li ($line0 .. $end) {
                my $fpos = _word_pos($lines[$li], $field_name);
                if (defined $fpos) {
                    push @tokens, [$li, $fpos, length($field_name), 'variable', $MOD_BIT{readonly}];
                    last;
                }
            }
        }

        # Type names inside field type strings: 'Int', 'Str', etc.
        _tokenize_quoted_types(\@tokens, \@lines, $line0, +{}, 10);
    }

    # ── declare declarations ─────────────────
    for my $name (keys(($extracted->{declares} // +{})->%*)) {
        my $decl = $extracted->{declares}{$name};
        my $line0 = ($decl->{line} // 1) - 1;
        next unless $line0 < @lines;

        # Function name (bare word or inside quotes)
        my $fn = $decl->{func_name};
        my $fn_pos = _word_pos($lines[$line0], $fn);
        push @tokens, [$line0, $fn_pos, length($fn), 'function', 0] if defined $fn_pos;

        # Type expression — find exact type_expr on line, tokenize content
        my $type_expr = $decl->{type_expr};
        my $type_start = index($lines[$line0], $type_expr);
        if ($type_start >= 0) {
            my %gen;
            if ($type_expr =~ /\A<([^>]+)>/) {
                %gen = map { s/\s*:.*//r => 1 } split /,\s*/, $1;
            }
            _tokenize_content(\@tokens, $line0, $type_start, $type_expr, \%gen);
        }
    }

    # ── function definitions ──────────────────
    for my $name (keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};
        my $line0 = ($fn->{line} // 1) - 1;
        next unless $line0 < @lines;

        # function name
        my $name_pos = _word_pos($lines[$line0], $name);
        if (defined $name_pos) {
            my $mods = $MOD_BIT{definition};
            push @tokens, [$line0, $name_pos, length($name), 'function', $mods];
        }

        # Tokenize :sig() annotation content
        my %generic_set;
        my $generics = $fn->{generics} // [];
        for my $g (@$generics) {
            my $gname = ref $g eq 'HASH' ? $g->{name} // $g : ref $g ? "$g" : $g;
            # Strip bound (e.g. "T: Num" → "T", "r: Row" → "r")
            $gname =~ s/\s*:.*\z// if defined $gname;
            $generic_set{$gname} = 1 if defined $gname && length $gname;
        }
        _tokenize_annotation(\@tokens, $line0, $lines[$line0], \%generic_set);
    }

    # ── variables ─────────────────────────────
    for my $var ($extracted->{variables}->@*) {
        next unless $var->{type_expr};  # only annotated variables
        my $line0 = ($var->{line} // 1) - 1;
        next unless $line0 < @lines;

        my $vname = $var->{name};
        my $vpos  = index($lines[$line0], $vname);
        if ($vpos >= 0) {
            my $mods = $MOD_BIT{declaration};
            push @tokens, [$line0, $vpos, length($vname), 'variable', $mods];
        }

        # Tokenize :sig() annotation content on variable lines
        _tokenize_annotation(\@tokens, $line0, $lines[$line0], +{});
    }

    # ── Typist keywords (PPI-based) ──────────
    if (my $ppi_doc = $extracted->{ppi_doc}) {
        my $words = $ppi_doc->find('PPI::Token::Word') || [];
        for my $w (@$words) {
            next unless $TYPIST_KEYWORD_SET{$w->content};
            my $line0 = $w->line_number - 1;
            my $col   = $w->column_number - 1;
            push @tokens, [$line0, $col, length($w->content), 'keyword', 0];
        }
    }

    # ── Delta Encoding ────────────────────────
    # Sort by line, then column
    @tokens = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @tokens;

    my @data;
    my ($prev_line, $prev_col) = (0, 0);

    for my $tok (@tokens) {
        my ($line, $col, $len, $type_name, $mods) = @$tok;
        my $delta_line = $line - $prev_line;
        my $delta_col  = $delta_line == 0 ? $col - $prev_col : $col;

        push @data, $delta_line, $delta_col, $len,
            $TYPE_INDEX{$type_name}, $mods;

        $prev_line = $line;
        $prev_col  = $col;
    }

    +{ data => \@data };
}

# ── Helpers ──────────────────────────────────────

# Find a defined name on a source line, push a token with definition modifier.
sub _scan_defined_name ($tokens, $lines, $line0, $name, $name_type) {
    return unless $line0 < scalar @$lines;
    my $text = $lines->[$line0];

    my $name_pos = _word_pos($text, $name);
    if (defined $name_pos) {
        my $mods = $MOD_BIT{definition};
        push @$tokens, [$line0, $name_pos, length($name), $name_type, $mods];
    }
}

# Tokenize type names and operators inside a :sig() annotation string.
sub _tokenize_annotation ($tokens, $line0, $line_text, $generic_names) {
    # Find :sig( in the line
    my $sig_start = index($line_text, ':sig(');
    return unless $sig_start >= 0;

    # Walk from the opening ( to find the matching )
    my $content_start = $sig_start + 5;  # first char after '('
    my $depth = 0;
    my $content_end = -1;
    for my $p ($content_start .. length($line_text) - 1) {
        my $ch = substr($line_text, $p, 1);
        if    ($ch eq '(') { $depth++ }
        elsif ($ch eq ')') {
            if ($depth == 0) { $content_end = $p; last }
            $depth--;
        }
    }
    return if $content_end < 0;

    my $content = substr($line_text, $content_start, $content_end - $content_start);
    _tokenize_content($tokens, $line0, $content_start, $content, $generic_names);
}

# Scan a type expression string for type names and operators, pushing tokens.
sub _tokenize_content ($tokens, $line0, $abs_col, $content, $generic_names) {
    my $pos = 0;
    while ($pos < length($content)) {
        my $rest = substr($content, $pos);

        # Identifier: word chars starting with a letter
        if ($rest =~ /\A([a-zA-Z][a-zA-Z0-9]*)/) {
            my $name = $1;
            my $col = $abs_col + $pos;
            if ($generic_names->{$name}) {
                # Known generic parameter (T, U, r, etc.)
                push @$tokens, [$line0, $col, length($name), 'typeParameter', 0];
            } elsif ($name =~ /\A[A-Z]/) {
                # Uppercase-starting: type name
                push @$tokens, [$line0, $col, length($name), 'type', 0];
            }
            # Lowercase non-generic identifiers are skipped (keywords like 'forall')
            $pos += length($name);
            next;
        }

        # Numeric literal: 0, 1, 42, etc.
        if ($rest =~ /\A(\d+)/) {
            push @$tokens, [$line0, $abs_col + $pos, length($1), 'number', 0];
            $pos += length($1);
            next;
        }

        # String literal: "ok", "error", etc.
        if ($rest =~ /\A("[^"]*")/) {
            push @$tokens, [$line0, $abs_col + $pos, length($1), 'string', 0];
            $pos += length($1);
            next;
        }

        # Arrow operator: ->
        if ($rest =~ /\A(->)/) {
            push @$tokens, [$line0, $abs_col + $pos, 2, 'operator', 0];
            $pos += 2;
            next;
        }

        # Effect operator: !
        if (substr($rest, 0, 1) eq '!') {
            push @$tokens, [$line0, $abs_col + $pos, 1, 'operator', 0];
            $pos += 1;
            next;
        }

        # Variadic: ...
        if ($rest =~ /\A(\.\.\.)/) {
            push @$tokens, [$line0, $abs_col + $pos, 3, 'operator', 0];
            $pos += 3;
            next;
        }

        # Single-char punctuation: parens, brackets, angles, union, intersection, comma, colon
        if ($rest =~ /\A([()\[\]<>|&,:])/) {
            push @$tokens, [$line0, $abs_col + $pos, 1, 'operator', 0];
            $pos += 1;
            next;
        }

        $pos++;
    }
}

# Tokenize operation/method names and their quoted sig strings in definition blocks.
sub _tokenize_sig_strings ($tokens, $lines, $line0, $operations, $generic_names = +{}) {
    my $end = ($line0 + 20 < $#$lines) ? $line0 + 20 : $#$lines;

    for my $li ($line0 .. $end) {
        my $text = $lines->[$li];

        for my $op_name (keys %$operations) {
            my $op_pos = _word_pos($text, $op_name);
            if (defined $op_pos) {
                push @$tokens, [$li, $op_pos, length($op_name), 'function', 0];
            }
        }
    }

    _tokenize_quoted_types($tokens, $lines, $line0, $generic_names);
}

# Tokenize type names inside quoted strings ('...') within a declaration block.
sub _tokenize_quoted_types ($tokens, $lines, $line0, $generic_names = +{}, $end_offset = 20) {
    my $end = ($line0 + $end_offset < $#$lines) ? $line0 + $end_offset : $#$lines;

    for my $li ($line0 .. $end) {
        my $text = $lines->[$li];
        while ($text =~ /'([^']+)'/g) {
            my $content = $1;
            my $match_end = pos($text);
            my $content_col = $match_end - length($content) - 1;  # first char inside quotes
            _tokenize_content($tokens, $li, $content_col, $content, $generic_names);
        }
    }
}

# Find the position of a whole word within a line. Returns 0-indexed column or undef.
sub _word_pos ($text, $word) {
    my $escaped = quotemeta($word);
    if ($text =~ /\b${escaped}\b/g) {
        return pos($text) - length($word);
    }
    undef;
}

1;

__END__

=head1 NAME

Typist::LSP::SemanticTokens - Semantic token classification for syntax highlighting

=head1 SYNOPSIS

    use Typist::LSP::SemanticTokens;

    # Get the token legend for LSP registration
    my $legend = Typist::LSP::SemanticTokens->legend;

    # Compute semantic tokens for an analyzed document
    my $result = Typist::LSP::SemanticTokens->compute($doc);
    # $result->{data} is the delta-encoded integer array

=head1 DESCRIPTION

Typist::LSP::SemanticTokens provides semantic token classification for
Typist-specific syntax elements. It processes analyzed documents and
produces the delta-encoded integer arrays required by the LSP semantic
tokens protocol.

=head1 TOKEN TYPES

The following token types are registered:

=over 4

=item C<type> - Type names in typedef/newtype/datatype declarations

=item C<typeParameter> - Type variable names in generic declarations

=item C<variable> - Annotated variable declarations

=item C<function> - Function name definitions

=item C<keyword> - Keywords (C<sub>, C<typedef>, C<newtype>, C<effect>, C<typeclass>, C<instance>, C<datatype>, C<enum>, C<struct>, C<declare>, C<handle>, C<match>, C<protocol>)

=item C<class> - Typeclass names

=item C<enum> - Effect names

=item C<enumMember> - Datatype variant (constructor) names

=back

=head1 TOKEN MODIFIERS

=over 4

=item C<declaration> - Annotated variable declarations

=item C<definition> - Function and type name definitions

=item C<readonly> - Struct field names (immutable)

=back

=head1 CLASS METHODS

=head2 legend

    my $legend = Typist::LSP::SemanticTokens->legend;

Returns the semantic tokens legend hashref with C<tokenTypes> and
C<tokenModifiers> arrays, suitable for the LSP C<initialize> response.

=head2 compute

    my $result = Typist::LSP::SemanticTokens->compute($doc);

Compute semantic tokens for the given analyzed L<Typist::LSP::Document>.
Returns C<< +{ data =E<gt> \@integers } >> where C<data> contains the
delta-encoded token array per the LSP specification.

=head1 SEE ALSO

L<Typist::LSP::Server>, L<Typist::LSP::Document>

=cut
