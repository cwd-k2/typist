use v5.40;
use Test::More;
use lib 'lib';

use Typist::Protocol;

# ── Construction ──────────────────────────────

subtest 'construction and accessors' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            None      => +{ connect => 'Connected' },
            Connected => +{ auth => 'Authed', disconnect => 'None' },
            Authed    => +{ query => 'Authed', disconnect => 'None' },
        },
    );

    ok defined $p, 'protocol created';
    is ref $p->transitions, 'HASH', 'transitions is hashref';
};

subtest 'construction requires transitions' => sub {
    eval { Typist::Protocol->new() };
    like $@, qr/requires transitions/, 'dies without transitions';
};

# ── next_state ────────────────────────────────

subtest 'next_state' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            None      => +{ connect => 'Connected' },
            Connected => +{ auth => 'Authed' },
        },
    );

    is $p->next_state('None', 'connect'), 'Connected', 'None + connect → Connected';
    is $p->next_state('Connected', 'auth'), 'Authed', 'Connected + auth → Authed';
    is $p->next_state('None', 'auth'), undef, 'None + auth → undef (disallowed)';
    is $p->next_state('Authed', 'connect'), undef, 'undefined state → undef';
};

# ── states ────────────────────────────────────

subtest 'states' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            None      => +{ connect => 'Connected' },
            Connected => +{ auth => 'Authed' },
        },
    );

    my @states = $p->states;
    is_deeply \@states, [qw(Authed Connected None)], 'all states (sorted)';
};

# ── ops_in ────────────────────────────────────

subtest 'ops_in' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            None      => +{ connect => 'Connected' },
            Connected => +{ auth => 'Authed', disconnect => 'None' },
        },
    );

    is_deeply [$p->ops_in('None')], ['connect'], 'ops in None';
    is_deeply [$p->ops_in('Connected')], [qw(auth disconnect)], 'ops in Connected';
    is_deeply [$p->ops_in('Authed')], [], 'ops in terminal state';
};

# ── validate ──────────────────────────────────

subtest 'validate — unreachable operations' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            None => +{ connect => 'Connected' },
        },
    );

    my @unreachable = $p->validate([qw(connect query disconnect)]);
    is_deeply \@unreachable, [qw(disconnect query)], 'unreachable ops (sorted)';

    my @all_ok = $p->validate([qw(connect)]);
    is_deeply \@all_ok, [], 'no unreachable when all covered';
};

done_testing;
