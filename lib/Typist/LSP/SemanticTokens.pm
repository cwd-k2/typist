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
        _scan_keyword_name(\@tokens, \@lines, $line0, 'typedef', $name, 'type');
    }

    # ── newtype declarations ──────────────────
    for my $name (keys $extracted->{newtypes}->%*) {
        my $info = $extracted->{newtypes}{$name};
        my $line0 = ($info->{line} // 1) - 1;
        _scan_keyword_name(\@tokens, \@lines, $line0, 'newtype', $name, 'type');
    }

    # ── effect declarations ───────────────────
    for my $name (keys $extracted->{effects}->%*) {
        my $info = $extracted->{effects}{$name};
        my $line0 = ($info->{line} // 1) - 1;
        _scan_keyword_name(\@tokens, \@lines, $line0, 'effect', $name, 'enum');
    }

    # ── typeclass declarations ────────────────
    for my $name (keys $extracted->{typeclasses}->%*) {
        my $info = $extracted->{typeclasses}{$name};
        my $line0 = ($info->{line} // 1) - 1;
        _scan_keyword_name(\@tokens, \@lines, $line0, 'typeclass', $name, 'class');
    }

    # ── datatype declarations ─────────────────
    for my $name (keys(($extracted->{datatypes} // +{})->%*)) {
        my $info = $extracted->{datatypes}{$name};
        my $line0 = ($info->{line} // 1) - 1;

        # Detect keyword: 'enum' vs 'datatype'
        my $kw = 'datatype';
        if ($line0 < @lines && $lines[$line0] =~ /\benum\b/) {
            $kw = 'enum';
        }

        _scan_keyword_name(\@tokens, \@lines, $line0, $kw, $name, 'type');

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
    }

    # ── function definitions ──────────────────
    for my $name (keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};
        my $line0 = ($fn->{line} // 1) - 1;
        next unless $line0 < @lines;

        # keyword 'sub'
        my $kw_pos = _word_pos($lines[$line0], 'sub');
        if (defined $kw_pos) {
            push @tokens, [$line0, $kw_pos, 3, 'keyword', 0];
        }

        # function name
        my $name_pos = _word_pos($lines[$line0], $name);
        if (defined $name_pos) {
            my $mods = $MOD_BIT{definition};
            push @tokens, [$line0, $name_pos, length($name), 'function', $mods];
        }

        # Type variables from generics
        my $generics = $fn->{generics} // [];
        for my $g (@$generics) {
            my $gname = ref $g eq 'HASH' ? $g->{name} // $g : ref $g ? "$g" : $g;
            next unless defined $gname && length $gname;
            # Search in the :Type() annotation on the function line
            my $gpos = _word_pos($lines[$line0], $gname);
            if (defined $gpos) {
                push @tokens, [$line0, $gpos, length($gname), 'typeParameter', 0];
            }
        }
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

# Find keyword and defined name on a source line, push tokens.
sub _scan_keyword_name ($tokens, $lines, $line0, $keyword, $name, $name_type) {
    return unless $line0 < scalar @$lines;
    my $text = $lines->[$line0];

    # Keyword token
    my $kw_pos = _word_pos($text, $keyword);
    if (defined $kw_pos) {
        push @$tokens, [$line0, $kw_pos, length($keyword), 'keyword', 0];
    }

    # Name token (with definition modifier)
    my $name_pos = _word_pos($text, $name);
    if (defined $name_pos) {
        my $mods = $MOD_BIT{definition};
        push @$tokens, [$line0, $name_pos, length($name), $name_type, $mods];
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

=item C<keyword> - Keywords (C<sub>, C<typedef>, C<newtype>, C<effect>, C<typeclass>, C<datatype>, C<enum>)

=item C<class> - Typeclass names

=item C<enum> - Effect names

=item C<enumMember> - Datatype variant (constructor) names

=back

=head1 TOKEN MODIFIERS

=over 4

=item C<declaration> - Annotated variable declarations

=item C<definition> - Function and type name definitions

=item C<readonly> - (reserved)

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
