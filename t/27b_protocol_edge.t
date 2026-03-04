use v5.40;
use Test::More;
use lib 'lib';
use Typist::Protocol;

# ── Self-loop state ─────────────────────────────

subtest 'self-loop state' => sub {
    my $proto = Typist::Protocol->new(
        transitions => +{
            Running => +{ tick => 'Running', stop => 'Stopped' },
            Stopped => +{},
        },
    );

    is $proto->next_state('Running', 'tick'), 'Running', 'self-loop: Running->tick->Running';
    is $proto->next_state('Running', 'stop'), 'Stopped', 'Running->stop->Stopped';
    is_deeply [$proto->ops_in('Running')], [qw(stop tick)], 'ops in Running (sorted)';
};

# ── Dead-end state ──────────────────────────────

subtest 'dead-end state' => sub {
    my $proto = Typist::Protocol->new(
        transitions => +{
            Start => +{ go => 'DeadEnd' },
            DeadEnd => +{},
        },
    );

    is $proto->next_state('Start', 'go'), 'DeadEnd', 'Start->go->DeadEnd';
    is_deeply [$proto->ops_in('DeadEnd')], [], 'no ops in dead-end state';
    is $proto->next_state('DeadEnd', 'go'), undef, 'no transition from dead-end';
};

# ── Unreachable state ──────────────────────────

subtest 'unreachable state (explicit states)' => sub {
    my $proto = Typist::Protocol->new(
        states => [qw(A B Unreachable)],
        transitions => +{
            A => +{ go => 'B' },
            B => +{},
        },
    );

    ok $proto->has_explicit_states, 'has explicit states';
    is_deeply [$proto->states], [qw(A B Unreachable)], 'all three states listed';
    is_deeply [$proto->ops_in('Unreachable')], [], 'unreachable has no ops';
};

# ── Branch convergence ──────────────────────────

subtest 'branch convergence' => sub {
    my $proto = Typist::Protocol->new(
        transitions => +{
            Start  => +{ left => 'PathA', right => 'PathB' },
            PathA  => +{ merge => 'End' },
            PathB  => +{ merge => 'End' },
            End    => +{},
        },
    );

    is $proto->next_state('Start', 'left'), 'PathA', 'left branch';
    is $proto->next_state('Start', 'right'), 'PathB', 'right branch';
    is $proto->next_state('PathA', 'merge'), 'End', 'PathA converges to End';
    is $proto->next_state('PathB', 'merge'), 'End', 'PathB converges to End';

    my @states = $proto->states;
    is scalar @states, 4, 'four states inferred';
};

# ── Single-state protocol ──────────────────────

subtest 'single-state protocol (all self-loops)' => sub {
    my $proto = Typist::Protocol->new(
        transitions => +{
            Active => +{ read => 'Active', write => 'Active' },
        },
    );

    is_deeply [$proto->states], ['Active'], 'single state';
    is $proto->next_state('Active', 'read'), 'Active', 'read self-loop';
    is $proto->next_state('Active', 'write'), 'Active', 'write self-loop';
};

# ── validate: unreachable operations ───────────

subtest 'validate finds unreachable operations' => sub {
    my $proto = Typist::Protocol->new(
        transitions => +{
            None      => +{ connect => 'Connected' },
            Connected => +{ query => 'Connected' },
        },
    );

    my @unreachable = $proto->validate([qw(connect query disconnect)]);
    is_deeply \@unreachable, ['disconnect'], 'disconnect is unreachable';

    my @all_ok = $proto->validate([qw(connect query)]);
    is_deeply \@all_ok, [], 'all ops reachable';
};

# ── next_state for nonexistent state ───────────

subtest 'next_state for unknown state' => sub {
    my $proto = Typist::Protocol->new(
        transitions => +{
            A => +{ go => 'B' },
        },
    );

    is $proto->next_state('X', 'go'), undef, 'unknown state returns undef';
    is $proto->next_state('A', 'unknown_op'), undef, 'unknown op returns undef';
};

# ── Explicit vs inferred states ────────────────

subtest 'explicit vs inferred states' => sub {
    my $trans = +{
        A => +{ go => 'B' },
        B => +{ back => 'A' },
    };

    my $inferred = Typist::Protocol->new(transitions => $trans);
    ok !$inferred->has_explicit_states, 'no explicit states';
    is_deeply [$inferred->states], [qw(A B)], 'inferred states';

    my $explicit = Typist::Protocol->new(
        transitions => $trans,
        states => [qw(A B C)],
    );
    ok $explicit->has_explicit_states, 'has explicit states';
    is_deeply [$explicit->states], [qw(A B C)], 'explicit states include C';
};

# ── Constructor requires transitions ───────────

subtest 'constructor requires transitions' => sub {
    eval { Typist::Protocol->new() };
    ok $@, 'dies without transitions';
    like $@, qr/requires transitions/, 'meaningful error message';
};

done_testing;
