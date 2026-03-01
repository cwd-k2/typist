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

# ── Annotation Suggestion Actions ───────────────

# Suggest type annotations for partially annotated functions.
sub suggest_annotations ($class, $doc, $registry) {
    my $result = $doc->{result} // return [];
    my $extracted = $result->{extracted} // return [];

    my @actions;
    my $functions = $extracted->{functions} // +{};

    for my $name (sort keys %$functions) {
        my $fn = $functions->{$name};
        next if $fn->{returns_expr};  # already has return annotation
        next if $fn->{unannotated};   # completely unannotated — intentional

        push @actions, +{
            title => "Add type annotation to $name()",
            kind  => 'quickfix',
        };
    }

    \@actions;
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
