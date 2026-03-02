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

=head1 NAME

Typist::Handler - Runtime effect handler stack (LIFO)

=head1 SYNOPSIS

    use Typist::Handler;

    Typist::Handler->push_handler('Console', +{
        writeLine => sub ($msg) { say $msg },
    });

    my $h = Typist::Handler->find_handler('Console');
    $h->{writeLine}->("hello");

    Typist::Handler->pop_handler;

=head1 DESCRIPTION

Maintains a LIFO stack of algebraic effect handlers. Each entry binds
an effect name to a hashref of operation implementations. The nearest
(most recently pushed) handler for a given effect wins when
C<find_handler> is called, enabling nested scoping where inner handlers
shadow outer ones.

Typically used via the C<handle { ... } Effect =E<gt> { ... }> syntax
exported by L<Typist>, not called directly.

=head1 METHODS

=head2 push_handler

    Typist::Handler->push_handler($effect_name, \%handlers);

Pushes a new handler frame onto the stack for the named effect.

=head2 pop_handler

    Typist::Handler->pop_handler;

Removes the topmost handler frame from the stack.

=head2 find_handler

    my $handlers = Typist::Handler->find_handler($effect_name);

Returns the handler hashref for the nearest matching effect, or C<undef>
if no handler is installed.

=head2 reset

    Typist::Handler->reset;

Clears the entire handler stack. Intended for testing.

=head1 SEE ALSO

L<Typist>, L<Typist::Effect>

=cut
