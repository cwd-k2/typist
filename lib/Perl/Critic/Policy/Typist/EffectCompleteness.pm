package Perl::Critic::Policy::Typist::EffectCompleteness;
use v5.40;

use parent 'Perl::Critic::Policy';

use Perl::Critic::Utils qw(:severities);

our $VERSION = '0.01';

# ── Policy Metadata ──────────────────────────────

sub supported_parameters ($) { () }
sub default_severity     ($) { $SEVERITY_MEDIUM }
sub default_themes       ($) { qw(typist) }
sub applies_to           ($) { 'PPI::Document' }

# ── Violation Detection ──────────────────────────

sub violates ($self, $doc_elem, $doc) {
    my $subs = $doc_elem->find('PPI::Statement::Sub') || [];

    my @violations;

    for my $sub_stmt (@$subs) {
        my $name = $sub_stmt->name;
        next unless defined $name;

        # Extract :Type annotation content
        my $attrs     = $sub_stmt->find('PPI::Token::Attribute') || [];
        my $type_text = undef;

        for my $attr (@$attrs) {
            my $content = $attr->content;
            if ($content =~ /\AType\((.+)\)\z/s) {
                $type_text = $1;
                last;
            }
        }

        # Check if annotation declares effects (has `!`)
        my $declares_effect = defined $type_text && $type_text =~ /!/;

        # Walk the sub body for qualified calls that look like effect operations
        my $words = $sub_stmt->find('PPI::Token::Word') || [];

        my $calls_effect_op = 0;
        for my $word (@$words) {
            my $val = $word->content;

            # Pattern: CapitalizedPkg::operation (e.g., Console::writeLine)
            next unless $val =~ /\A[A-Z][A-Za-z0-9]*::[a-z]\w*\z/;

            # Skip well-known non-effect qualified calls
            next if $val =~ /\A(?:Typist|Perl|PPI|Test|CORE|POSIX|Carp|Scalar|List|File|IO|Exporter|JSON|MIME|HTTP|LWP|URI|DBI)::/;

            $calls_effect_op = 1;
            last;
        }

        next unless $calls_effect_op;
        next if $declares_effect;

        push @violations, $self->violation(
            "Sub '$name' calls effect operations without declaring effects (missing '!' in :Type)",
            "Functions that call effect operations (e.g., Console::writeLine) should declare their effects in the :Type annotation using '!' syntax",
            $sub_stmt,
        );
    }

    @violations;
}

1;

__END__

=head1 NAME

Perl::Critic::Policy::Typist::EffectCompleteness - Require effect declarations for effectful subs

=head1 DESCRIPTION

This policy detects functions that call effectful operations (qualified calls
matching C<CapitalizedPkg::operation> pattern) without declaring their effects
in the C<:Type()> annotation via the C<!> syntax.

For example, a function calling C<Console::writeLine()> should have
C<:Type((Str) -> Void ! Console)>.

=head1 CONFIGURATION

    [Typist::EffectCompleteness]
    severity = 3

=cut
