package Typist::LSP::CodeAction;
use v5.40;

our $VERSION = '0.01';

# ── Code Action Generation ──────────────────────

# Generate code actions for diagnostics in a given range.
# Diagnostics arrive from the client with our internal metadata
# stashed in the `data` field by _publish_diagnostics.
sub actions_for_diagnostics ($class, $diagnostics, $doc, $registry) {
    my @actions;

    for my $diag (@$diagnostics) {
        my $data = $diag->{data} // next;
        my $kind = $data->{_typist_kind} // next;

        if ($kind eq 'EffectMismatch') {
            my $action = $class->_suggest_add_effect($diag, $doc);
            push @actions, $action if $action;
        }

        if ($kind eq 'TypeMismatch') {
            if ($data->{_suggestions}) {
                for my $suggestion (@{$data->{_suggestions}}) {
                    push @actions, $class->_make_suggestion_action($diag, $suggestion, $doc);
                }
            }
            if (my $action = $class->_suggest_type_fix($diag, $doc)) {
                push @actions, $action;
            }
        }
    }

    \@actions;
}

# ── Effect Mismatch Actions ─────────────────────

# Suggest adding a missing effect to the caller's annotation.
# Parses the EffectMismatch message to extract effect label and function name.
sub _suggest_add_effect ($class, $diag, $doc) {
    my $msg = $diag->{message} // return undef;

    # Pattern 1: "Function foo() calls bar() which requires effect 'Console', but foo() does not declare it"
    # Pattern 2: "Function foo() calls bar() which requires [Console], but foo() has no effect annotation"
    # Pattern 3: "Function foo() calls unannotated bar() which may perform any effect"

    my ($effect_label) = $msg =~ /effect '(\w+)'/;
    unless ($effect_label) {
        ($effect_label) = $msg =~ /requires \[([^\]]+)\]/;
    }
    return undef unless $effect_label;

    my ($fn_name) = $msg =~ /\AFunction (\w+)\(\)/;
    return undef unless $fn_name;

    my $action = +{
        title       => "Add effect '$effect_label' to $fn_name()",
        kind        => 'quickfix',
        diagnostics => [$class->_strip_internal($diag)],
    };

    # Try to generate a WorkspaceEdit for the :sig() annotation
    my $edit = $class->_build_effect_edit($doc, $fn_name, $effect_label);
    $action->{edit} = $edit if $edit;

    $action;
}

# Build a WorkspaceEdit that adds an effect label to a function's :sig() annotation.
sub _build_effect_edit ($class, $doc, $fn_name, $effect_label) {
    my $lines = $doc->lines;
    return undef unless $lines && @$lines;
    my $uri = $doc->uri;

    # Find the :sig(...) annotation line for the target function
    for my $i (0 .. $#$lines) {
        my $line = $lines->[$i];

        # Match: sub fn_name :sig(...) pattern on single line
        next unless $line =~ /\bsub\s+\Q$fn_name\E\b/;
        next unless $line =~ /:sig\(/;

        # Determine edit position
        my ($new_line, $col);

        if ($line =~ /!\[([^\]]*)\]/) {
            # Already has ![...] — add , Label before the closing ]
            my $eff_close = index($line, ']', $-[0] + 1);
            return undef if $eff_close < 0;
            $new_line = substr($line, 0, $eff_close)
                      . ", $effect_label"
                      . substr($line, $eff_close);
        } else {
            # No ![...] — insert before the closing ) of :sig(...)
            # Find the last ) that closes :sig(
            my $type_start = index($line, ':sig(');
            return undef if $type_start < 0;

            # Walk from :sig( to find matching )
            my $depth = 0;
            my $close_pos = -1;
            for my $p ($type_start + 5 .. length($line) - 1) {
                my $ch = substr($line, $p, 1);
                if ($ch eq '(') { $depth++ }
                elsif ($ch eq ')') {
                    if ($depth == 0) {
                        $close_pos = $p;
                        last;
                    }
                    $depth--;
                }
            }
            return undef if $close_pos < 0;

            $new_line = substr($line, 0, $close_pos)
                      . " ![$effect_label]"
                      . substr($line, $close_pos);
        }

        return +{
            changes => +{
                $uri => [+{
                    range => +{
                        start => +{ line => $i, character => 0 },
                        end   => +{ line => $i, character => length($line) },
                    },
                    newText => $new_line,
                }],
            },
        };
    }

    undef;
}

# ── TypeMismatch Auto-Fix Actions ──────────────

# Suggest changing the annotation type to match the actual type.
sub _suggest_type_fix ($class, $diag, $doc) {
    my $data     = $diag->{data} // +{};
    my $expected = $data->{_expected_type} // return undef;
    my $actual   = $data->{_actual_type}   // return undef;
    my $msg      = $diag->{message} // '';
    my $lines    = $doc->lines;
    my $uri      = $doc->uri;
    my $diag_line = $diag->{range}{start}{line};

    # Case 1: "Return value of foo(): expected X, got Y"
    # or "Implicit return of foo(): expected X, got Y"
    if ($msg =~ /(?:Return value|Implicit return) of (\w+)\(\)/) {
        my $fn = $1;
        for my $i (0 .. $#$lines) {
            my $l = $lines->[$i];
            next unless $l =~ /\bsub\s+\Q$fn\E\b/ && $l =~ /:sig\(/;
            (my $new = $l) =~ s/\Q$expected\E/$actual/;
            next if $new eq $l;
            return +{
                title       => "Change return type to $actual",
                kind        => 'quickfix',
                diagnostics => [$class->_strip_internal($diag)],
                edit => +{ changes => +{ $uri => [+{
                    range   => +{
                        start => +{ line => $i, character => 0 },
                        end   => +{ line => $i, character => length($l) },
                    },
                    newText => $new,
                }] } },
            };
        }
    }

    # Case 2: "Variable $x: expected X, got Y" or "Assignment to $x: expected X, got Y"
    if ($msg =~ /(?:Variable|Assignment to) (\$\w+):/) {
        my $var = $1;
        # Search for the :sig() declaration line for this variable
        for my $i (0 .. $#$lines) {
            my $l = $lines->[$i];
            next unless $l =~ /\Q$var\E\b/ && $l =~ /:sig\(/;
            (my $new = $l) =~ s/:sig\(\Q$expected\E\)/:sig($actual)/;
            next if $new eq $l;
            return +{
                title       => "Change type annotation to $actual",
                kind        => 'quickfix',
                diagnostics => [$class->_strip_internal($diag)],
                edit => +{ changes => +{ $uri => [+{
                    range   => +{
                        start => +{ line => $i, character => 0 },
                        end   => +{ line => $i, character => length($l) },
                    },
                    newText => $new,
                }] } },
            };
        }
    }

    undef;
}

# ── Suggestion-Based Actions ────────────────────

sub _make_suggestion_action ($class, $diag, $suggestion, $doc) {
    +{
        title       => $suggestion,
        kind        => 'quickfix',
        diagnostics => [$class->_strip_internal($diag)],
    };
}

# ── Internal Helpers ────────────────────────────

# Strip internal data field before sending diagnostic references back.
# The LSP client expects the same diagnostic shape it originally sent.
sub _strip_internal ($class, $diag) {
    my %copy = %$diag;
    delete $copy{data};
    \%copy;
}

1;

__END__

=head1 NAME

Typist::LSP::CodeAction - Quick-fix code action generation

=head1 SYNOPSIS

    use Typist::LSP::CodeAction;

    my $actions = Typist::LSP::CodeAction->actions_for_diagnostics(
        \@diagnostics, $doc, $registry,
    );

=head1 DESCRIPTION

Typist::LSP::CodeAction generates LSP code actions (quick-fixes) from
diagnostics produced by the Typist static analyzer. It inspects the
internal metadata attached to each diagnostic to determine which
actions are applicable.

=head1 CLASS METHODS

=head2 actions_for_diagnostics

    my $actions = Typist::LSP::CodeAction->actions_for_diagnostics(
        \@diagnostics, $doc, $registry,
    );

Generate code actions for the given diagnostics. Currently supports:

=over 4

=item B<EffectMismatch> - Suggests adding the missing effect to the caller's annotation

=item B<TypeMismatch with suggestions> - Generates quick-fix actions from attached suggestion strings

=back

Returns an arrayref of LSP CodeAction objects with C<kind =E<gt> 'quickfix'>.

=head1 SEE ALSO

L<Typist::LSP::Server>, L<Typist::LSP::Document>

=cut
