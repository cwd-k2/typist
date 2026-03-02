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

        if ($kind eq 'TypeMismatch' && $data->{_suggestions}) {
            for my $suggestion (@{$data->{_suggestions}}) {
                push @actions, $class->_make_suggestion_action($diag, $suggestion, $doc);
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
    # Pattern 2: "Function foo() calls bar() which requires Eff(Console), but foo() has no :Eff annotation"
    # Pattern 3: "Function foo() calls unannotated bar() which may perform any effect"

    my ($effect_label) = $msg =~ /effect '(\w+)'/;
    unless ($effect_label) {
        ($effect_label) = $msg =~ /requires Eff\(([^)]+)\)/;
    }
    return undef unless $effect_label;

    my ($fn_name) = $msg =~ /\AFunction (\w+)\(\)/;
    return undef unless $fn_name;

    +{
        title       => "Add effect '$effect_label' to $fn_name()",
        kind        => 'quickfix',
        diagnostics => [$class->_strip_internal($diag)],
    };
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
