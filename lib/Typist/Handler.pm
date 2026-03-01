package Typist::Handler;
use v5.40;

our $VERSION = '0.01';

# ── Effect Handler Stack ─────────────────────────
#
# Runtime infrastructure for algebraic effect handlers.
# Maintains a LIFO stack of effect handlers. Each entry binds
# an effect name to a hashref of operation implementations.
#
#   Typist::Handler->push_handler('Console', +{
#       log => sub ($msg) { say $msg },
#   });
#
# The nearest (most recently pushed) handler for a given effect
# wins when `find_handler` is called. This enables nested scoping:
# inner handlers shadow outer ones for the same effect.

my @HANDLER_STACK;

sub push_handler ($class, $effect_name, $handlers) {
    push @HANDLER_STACK, +{
        effect   => $effect_name,
        handlers => $handlers,
    };
}

sub pop_handler ($class) {
    pop @HANDLER_STACK;
}

sub find_handler ($class, $effect_name) {
    for my $entry (reverse @HANDLER_STACK) {
        return $entry->{handlers} if $entry->{effect} eq $effect_name;
    }
    undef;
}

# Reset the handler stack (for testing).
sub reset ($class) {
    @HANDLER_STACK = ();
}

1;
