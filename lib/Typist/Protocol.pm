package Typist::Protocol;
use v5.40;

our $VERSION = '0.01';

# Protocol: a finite state machine attached to an Effect definition.
# Maps (state, operation) pairs to successor states.
#
#   { transitions => { None => { connect => 'Connected' }, ... } }

sub new ($class, %args) {
    my $transitions = $args{transitions}
        // die("Protocol requires transitions\n");
    bless +{
        transitions => $transitions,
        _states     => $args{states},   # explicit states list (arrayref or undef)
    }, $class;
}

sub transitions ($self) { $self->{transitions} }

# Successor state for (state, op), or undef if disallowed.
sub next_state ($self, $state, $op) {
    my $state_map = $self->{transitions}{$state} // return undef;
    $state_map->{$op};
}

# All declared states.
# Uses explicit states list if provided at construction (preserving declaration
# order -- the first element is the initial state by convention); otherwise
# infers from transitions (sorted for determinism).
sub states ($self) {
    if ($self->{_states}) {
        return $self->{_states}->@*;
    }
    my %seen;
    for my $from (keys $self->{transitions}->%*) {
        $seen{$from} = 1;
        $seen{$_} = 1 for values $self->{transitions}{$from}->%*;
    }
    sort keys %seen;
}

sub has_explicit_states ($self) { defined $self->{_states} && $self->{_states}->@* > 0 }

# The first element of the explicit states list, or undef.
sub initial_state ($self) {
    return $self->{_states}[0] if $self->{_states} && $self->{_states}->@*;
    undef;
}

# Operations valid in a given state.
sub ops_in ($self, $state) {
    my $state_map = $self->{transitions}{$state} // return ();
    sort keys %$state_map;
}

# Operations that are unreachable from any state.
sub validate ($self, $effect_ops) {
    my %reachable;
    for my $state_map (values $self->{transitions}->%*) {
        $reachable{$_} = 1 for keys %$state_map;
    }
    sort grep { !$reachable{$_} } @$effect_ops;
}

1;

__END__

=head1 NAME

Typist::Protocol - Finite state machine for effect protocol verification

=head1 DESCRIPTION

Typist::Protocol models a finite state machine attached to an Effect
definition. It maps C<(state, operation)> pairs to successor states,
enabling static verification of operation sequencing.

=head2 new

    my $proto = Typist::Protocol->new(
        transitions => +{ None => +{ connect => 'Connected' } },
        states      => [qw(None Connected)],
    );

Construct a new Protocol from a transitions hash. The optional C<states>
argument provides an explicit states list; otherwise states are inferred
from the transitions.

=head2 transitions

    my $map = $proto->transitions;

Returns the raw transitions hashref mapping each state to its
C<< { operation => successor_state } >> entries.

=head2 next_state

    my $next = $proto->next_state($state, $op);

Returns the successor state for the given C<($state, $op)> pair, or
C<undef> if the operation is not allowed in that state.

=head2 states

    my @states = $proto->states;

Returns all declared states. When an explicit states list was provided at
construction, returns them in declaration order (the first element is the
initial state by convention). Otherwise infers states from the transitions
and returns them sorted for determinism.

=head2 has_explicit_states

    my $bool = $proto->has_explicit_states;

Returns true if the protocol was constructed with an explicit states
list rather than relying on inference from transitions.

=head2 initial_state

    my $state = $proto->initial_state;

Returns the initial state of the protocol -- the first element of the
explicit states list provided at construction. Returns C<undef> if no
explicit states were given.

By convention, the first element of the states list is always the initial
state. Functions that begin a protocol session annotate this state as their
C<From> state.

=head2 ops_in

    my @ops = $proto->ops_in($state);

Returns a sorted list of operations that are valid in the given state.

=head2 validate

    my @unreachable = $proto->validate(\@effect_ops);

Given a list of all operations defined on the parent effect, returns
those that are unreachable from any state in the protocol.

=head1 SEE ALSO

L<Typist::Effect>, L<Typist::Static::ProtocolChecker>

=cut
