package Perl::Critic::Policy::Typist::ExhaustivenessCheck;
use v5.40;

use parent 'Perl::Critic::Policy';

use Perl::Critic::Utils qw(:severities);

our $VERSION = '0.01';

# ── Policy Metadata ──────────────────────────────

sub supported_parameters ($) { () }
sub default_severity     ($) { $SEVERITY_LOW }
sub default_themes       ($) { qw(typist) }
sub applies_to           ($) { 'PPI::Document' }

# ── Violation Detection ──────────────────────────

sub violates ($self, $doc_elem, $doc) {
    my $words = $doc_elem->find('PPI::Token::Word') || [];

    my @violations;

    for my $word (@$words) {
        next unless $word->content eq 'match';

        # Walk forward from the match keyword to the end of its statement
        my $stmt = $word->statement;
        next unless $stmt;

        # Look for a `_` fat-comma pattern indicating a fallback arm
        my $has_fallback = _has_fallback_arm($stmt);

        next if $has_fallback;

        push @violations, $self->violation(
            "match expression may not be exhaustive (no '_' fallback arm)",
            "match expressions without a '_' fallback arm may fail at runtime if an unhandled variant is encountered",
            $word,
        );
    }

    @violations;
}

# ── Helpers ──────────────────────────────────────

sub _has_fallback_arm ($stmt) {
    # Search all tokens in the statement for `_` followed by `=>`
    my $tokens = $stmt->find('PPI::Token') || [];

    for my $i (0 .. $#$tokens) {
        my $tok = $tokens->[$i];

        # Look for `_` as a Word or Magic token
        next unless $tok->content eq '_';

        # Find next significant token
        for my $j ($i + 1 .. $#$tokens) {
            my $next = $tokens->[$j];
            next if $next->isa('PPI::Token::Whitespace');

            # `_` followed by `=>` means fallback arm
            return 1 if $next->content eq '=>';
            last;
        }
    }

    return 0;
}

1;

__END__

=head1 NAME

Perl::Critic::Policy::Typist::ExhaustivenessCheck - Warn on non-exhaustive match expressions

=head1 DESCRIPTION

This policy detects C<match> expressions that may not be exhaustive. A
C<match> without a C<_> fallback arm could fail at runtime if an unhandled
variant is encountered.

=head1 CONFIGURATION

    [Typist::ExhaustivenessCheck]
    severity = 4

=cut
