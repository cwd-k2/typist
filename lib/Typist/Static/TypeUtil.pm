package Typist::Static::TypeUtil;
use v5.40;

our $VERSION = '0.01';

use Exporter 'import';
our @EXPORT_OK = qw(widen_literal contains_any contains_placeholder);

use List::Util 'any';
use Typist::Type::Atom;
use Typist::Type::Param;

# ── Literal Widening ────────────────────────────

# Widen literal types for mutable variable bindings.
# Literal(42, 'Int') → Atom('Int'), Literal(true, 'Bool') → Atom('Int')
# Recurses into Param: Option[42] → Option[Int]
sub widen_literal ($type) {
    if ($type->is_literal) {
        my $base = $type->base_type;
        $base = 'Int' if $base eq 'Bool';
        return Typist::Type::Atom->new($base);
    }
    if ($type->is_param && $type->params) {
        my @args = $type->params;
        my $changed;
        my @widened = map {
            my $w = widen_literal($_);
            $changed = 1 if !$w->equals($_);
            $w;
        } @args;
        return Typist::Type::Param->new($type->base, @widened) if $changed;
    }
    $type;
}

# ── Gradual Typing Guards ───────────────────────

# Check whether a type transitively contains Any (gradual typing marker).
sub contains_any ($type) {
    return 1 if $type->is_atom && $type->name eq 'Any';
    if ($type->is_func) {
        return 1 if any { contains_any($_) } $type->params;
        return 1 if contains_any($type->returns);
    }
    if ($type->is_union) {
        return 1 if any { contains_any($_) } $type->members;
    }
    return 1 if contains_placeholder($type);
    0;
}

# Check whether a type transitively contains the '_' placeholder.
sub contains_placeholder ($type) {
    return 1 if $type->is_atom && $type->name eq '_';
    if ($type->is_param) {
        return 1 if any { contains_placeholder($_) } $type->params;
    }
    if ($type->is_func) {
        return 1 if any { contains_placeholder($_) } $type->params;
        return 1 if contains_placeholder($type->returns);
    }
    if ($type->is_union) {
        return 1 if any { contains_placeholder($_) } $type->members;
    }
    0;
}

1;

=head1 NAME

Typist::Static::TypeUtil - Shared type analysis utilities

=head1 DESCRIPTION

Pure functions for type structure analysis, shared across the static
analysis pipeline (TypeChecker, CallChecker, TypeEnv).

=head1 FUNCTIONS

=head2 widen_literal

    my $widened = widen_literal($type);

Widen literal types to their base atoms for mutable variable bindings.

=head2 contains_any

    my $bool = contains_any($type);

Check whether a type transitively contains C<Any> (gradual typing marker).

=head2 contains_placeholder

    my $bool = contains_placeholder($type);

Check whether a type transitively contains the C<_> placeholder.

=cut
