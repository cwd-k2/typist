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

    # Build op_map from transitions (back-compat) or accept directly.
    # op_map: { op_name => { from => [states], to => [states] } }
    my $op_map = $args{op_map};
    unless ($op_map) {
        my %om;
        for my $from (keys %$transitions) {
            for my $op (keys $transitions->{$from}->%*) {
                my $to = $transitions->{$from}{$op};
                $om{$op} //= { from => [], to => undef };
                push $om{$op}{from}->@*, $from;
                $om{$op}{to} = [$to];  # scalar targets in legacy format
            }
        }
        # Deduplicate and sort from-sets
        for my $entry (values %om) {
            my %seen;
            $entry->{from} = [sort grep { !$seen{$_}++ } $entry->{from}->@*];
        }
        $op_map = \%om;
    }

    bless +{
        transitions => $transitions,
        op_map      => $op_map,
        _states     => $args{states},   # explicit states list (arrayref or undef)
    }, $class;
}

sub transitions ($self) { $self->{transitions} }
sub op_map      ($self) { $self->{op_map} }

# Successor state for (state, op), or undef if disallowed.
# Back-compat: delegates to next_states for single-state input.
sub next_state ($self, $state, $op) {
    my $result = $self->next_states([$state], $op);
    return undef unless $result;
    # Return first element for scalar back-compat
    $result->[0];
}

# Set-based successor: given a current state set (arrayref), returns the
# to-set (arrayref) if current_set is valid for the op, or undef.
# '*' in current_set is a wildcard that matches any from-state.
sub next_states ($self, $current_set, $op) {
    my $entry = $self->{op_map}{$op} // return undef;
    my $from = $entry->{from};

    # Check: current_set ⊆ from
    # '*' is a literal ground state — only matches if explicitly in from-set.
    my %from_set = map { $_ => 1 } @$from;
    for my $s (@$current_set) {
        next if $from_set{$s};
        return undef;                # current state not in from-set
    }

    $entry->{to};
}

# All declared states.
# Uses explicit states list if provided at construction (preserving declaration
# order -- the first element is the initial state by convention); otherwise
# infers from transitions (sorted for determinism).
# '*' (ground state) is implicit and excluded unless explicitly declared.
sub states ($self) {
    if ($self->{_states}) {
        return $self->{_states}->@*;
    }
    my %seen;
    for my $from (keys $self->{transitions}->%*) {
        $seen{$from} = 1;
        $seen{$_} = 1 for values $self->{transitions}{$from}->%*;
    }
    delete $seen{'*'};
    sort keys %seen;
}

sub has_explicit_states ($self) { defined $self->{_states} && $self->{_states}->@* > 0 }

# The first element of the explicit states list, or undef.
sub initial_state ($self) {
    return $self->{_states}[0] if $self->{_states} && $self->{_states}->@*;
    undef;
}

# Operations valid in a given state.
# '*' (ground state) returns only ops whose from-set contains '*'.
sub ops_in ($self, $state) {
    my %ops;
    for my $op (keys $self->{op_map}->%*) {
        my $from = $self->{op_map}{$op}{from};
        my %from_set = map { $_ => 1 } @$from;
        $ops{$op} = 1 if $from_set{$state};
    }
    sort keys %ops;
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
