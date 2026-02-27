package Perl::Critic::Policy::Typist::TypeCheck;
use v5.40;

use parent 'Perl::Critic::Policy';

use Perl::Critic::Utils qw(:severities);
use Typist::Static::Analyzer;

our $VERSION = '0.01';

# ── Severity Mapping ─────────────────────────────

my %SEVERITY_MAP = (
    CycleError       => $SEVERITY_HIGHEST,   # 5
    TypeError        => $SEVERITY_HIGH,       # 4
    ResolveError     => $SEVERITY_HIGH,       # 4
    UndeclaredTypeVar => $SEVERITY_MEDIUM,    # 3
    UnknownType      => $SEVERITY_LOW,        # 2
);

# ── Policy Metadata ──────────────────────────────

sub supported_parameters ($) { () }
sub default_severity     ($) { $SEVERITY_LOW }
sub default_themes       ($) { qw(typist) }
sub applies_to           ($) { 'PPI::Document' }

# ── Violation Detection ──────────────────────────

sub violates ($self, $doc_elem, $doc) {
    my $source = $doc->content;
    my $result = Typist::Static::Analyzer->analyze($source, file => $doc->filename // '(buffer)');

    my @violations;

    for my $diag ($result->{diagnostics}->@*) {
        my $severity = $SEVERITY_MAP{$diag->{kind}} // $SEVERITY_LOW;

        # Find the PPI element closest to the diagnostic line
        my $elem = _find_element_at_line($doc, $diag->{line}) // $doc_elem;

        push @violations, $self->violation(
            "[$diag->{kind}] $diag->{message}",
            "Typist type checker detected: $diag->{message}",
            $elem,
            severity => $severity,
        );
    }

    @violations;
}

# ── Helpers ──────────────────────────────────────

sub _find_element_at_line ($doc, $target_line) {
    return undef unless $target_line && $target_line > 0;

    # Search for any significant token at or near the target line
    my $tokens = $doc->find('PPI::Token') || [];
    for my $tok (@$tokens) {
        next unless $tok->line_number;
        return $tok if $tok->line_number == $target_line;
    }

    undef;
}

1;

__END__

=head1 NAME

Perl::Critic::Policy::Typist::TypeCheck - Validate Typist type annotations

=head1 DESCRIPTION

This policy uses the Typist static analyzer to detect type errors in Perl
source code that uses the Typist type system. It checks for:

=over 4

=item * Alias cycles (severity 5)

=item * Type errors and resolve errors (severity 4)

=item * Undeclared type variables (severity 3)

=item * Unknown type aliases (severity 2)

=back

=head1 CONFIGURATION

    [Typist::TypeCheck]
    severity = 2

=cut
