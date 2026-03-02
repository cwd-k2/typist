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

# Sorted list of all declared states.
# Uses explicit states list if provided at construction; otherwise infers from transitions.
sub states ($self) {
    if ($self->{_states}) {
        return sort $self->{_states}->@*;
    }
    my %seen;
    for my $from (keys $self->{transitions}->%*) {
        $seen{$from} = 1;
        $seen{$_} = 1 for values $self->{transitions}{$from}->%*;
    }
    sort keys %seen;
}

sub has_explicit_states ($self) { defined $self->{_states} && $self->{_states}->@* > 0 }

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
