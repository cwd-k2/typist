package Perl::Critic::Policy::Typist::AnnotationStyle;
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
    my $subs = $doc_elem->find('PPI::Statement::Sub') || [];

    my @violations;

    for my $sub_stmt (@$subs) {
        my $name = $sub_stmt->name;
        next unless defined $name;

        # Skip private subs (underscore convention)
        next if $name =~ /\A_/;

        # Check for :Type attribute
        my $attrs = $sub_stmt->find('PPI::Token::Attribute') || [];
        my $has_type = grep { $_->content =~ /\Asig\b/ } @$attrs;

        next if $has_type;

        push @violations, $self->violation(
            "Public sub '$name' lacks :sig() annotation",
            "All public subroutines should have a :sig() annotation for static type checking",
            $sub_stmt,
        );
    }

    @violations;
}

1;

__END__

=head1 NAME

Perl::Critic::Policy::Typist::AnnotationStyle - Require :sig() on public subs

=head1 DESCRIPTION

This policy detects public subroutines (not starting with C<_>) that lack
a C<:sig()> annotation. In a Typist codebase, every public function should
carry a type signature for static analysis and documentation.

=head1 CONFIGURATION

    [Typist::AnnotationStyle]
    severity = 4

=cut
