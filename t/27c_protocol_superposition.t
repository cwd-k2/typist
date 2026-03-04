use v5.40;
use Test::More;
use lib 'lib';

use Typist::Protocol;
use Typist::Parser;
use Typist::Type::Row;

# ── op_map accessor ──────────────────────────────

subtest 'op_map — auto-built from transitions' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            None      => +{ connect => 'Connected' },
            Connected => +{ auth => 'Authed', disconnect => 'None' },
            Authed    => +{ query => 'Authed', disconnect => 'None' },
        },
    );

    my $om = $p->op_map;
    ok ref $om eq 'HASH', 'op_map is hashref';
    is_deeply $om->{connect}{from}, ['None'], 'connect from-set';
    is_deeply $om->{connect}{to}, ['Connected'], 'connect to-set';
    is_deeply [sort $om->{disconnect}{from}->@*], [qw(Authed Connected)], 'disconnect from-set (multi)';
    is_deeply $om->{disconnect}{to}, ['None'], 'disconnect to-set';
};

subtest 'op_map — direct construction' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            A => +{ go => 'B' },
            B => +{ go => 'C' },
        },
        op_map => +{
            go => { from => ['A', 'B'], to => ['B', 'C'] },
        },
    );

    my $om = $p->op_map;
    is_deeply $om->{go}{from}, ['A', 'B'], 'direct op_map from';
    is_deeply $om->{go}{to}, ['B', 'C'], 'direct op_map to';
};

# ── next_states ──────────────────────────────────

subtest 'next_states — single-state input' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            None      => +{ connect => 'Connected' },
            Connected => +{ auth => 'Authed' },
        },
    );

    is_deeply $p->next_states(['None'], 'connect'), ['Connected'], 'None->connect->Connected';
    is_deeply $p->next_states(['Connected'], 'auth'), ['Authed'], 'Connected->auth->Authed';
    is $p->next_states(['None'], 'auth'), undef, 'None->auth->undef';
    is $p->next_states(['Authed'], 'connect'), undef, 'Authed->connect->undef';
};

subtest 'next_states — * is literal ground state, not wildcard' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            None => +{ connect => 'Connected' },
        },
    );

    # * is a literal ground state — does NOT wildcard-match from-sets
    is $p->next_states(['*'], 'connect'), undef, '* does not wildcard-match None';

    # * only matches if explicitly in from-set
    my $p2 = Typist::Protocol->new(
        transitions => +{
            '*'  => +{ init => 'None' },
            None => +{ connect => 'Connected' },
        },
        op_map => +{
            init    => { from => ['*'], to => ['None'] },
            connect => { from => ['None'], to => ['Connected'] },
        },
    );
    is_deeply $p2->next_states(['*'], 'init'), ['None'], '* matches literal * in from-set';
    is $p2->next_states(['*'], 'connect'), undef, '* does not match None in from-set';
};

subtest 'next_states — multi-state set input' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            A => +{ go => 'C' },
            B => +{ go => 'C' },
        },
        op_map => +{
            go => { from => ['A', 'B'], to => ['C'] },
        },
    );

    is_deeply $p->next_states(['A', 'B'], 'go'), ['C'], 'A|B->go->C';
    is_deeply $p->next_states(['A'], 'go'), ['C'], 'A->go->C (subset)';
    is $p->next_states(['A', 'X'], 'go'), undef, 'A|X->go->undef (X not in from)';
};

# ── ops_in ───────────────────────────────────────

subtest 'ops_in — * ground state returns only ops with * in from' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            '*'  => +{ init => 'None' },
            None => +{ connect => 'Connected' },
        },
        op_map => +{
            init    => { from => ['*'], to => ['None'] },
            connect => { from => ['None'], to => ['Connected'] },
        },
    );

    my @ops = $p->ops_in('*');
    is_deeply \@ops, [qw(init)], '* only matches ops with * in from-set';
};

# ── states excludes * ────────────────────────────

subtest 'states — * excluded from inferred' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            '*' => +{ init => 'None' },
            None => +{ connect => 'Connected' },
        },
    );

    my @states = $p->states;
    ok !grep({ $_ eq '*' } @states), '* excluded from inferred states';
    is_deeply \@states, [qw(Connected None)], 'inferred states without *';
};

# ── next_state back-compat ───────────────────────

subtest 'next_state — scalar back-compat' => sub {
    my $p = Typist::Protocol->new(
        transitions => +{
            None => +{ connect => 'Connected' },
        },
    );

    is $p->next_state('None', 'connect'), 'Connected', 'back-compat scalar return';
    is $p->next_state('None', 'auth'), undef, 'back-compat undef';
};

# ── Parser: *, _ and | in _parse_effect_row ──────

subtest 'parser — ![Effect<* -> *>] (ground state)' => sub {
    my $func = Typist::Parser->parse('() -> Void ![DB<* -> *>]');
    ok $func->is_func, 'parsed as func';
    my $row = $func->effects;
    my $st = $row->label_state('DB');
    is_deeply $st->{from}, ['*'], 'from is [*]';
    is_deeply $st->{to}, ['*'], 'to is [*]';
    like $row->to_string, qr/DB<\*>/, 'to_string shows DB<*> (invariant)';
};

subtest 'parser — ![Effect<A | B -> C>]' => sub {
    my $func = Typist::Parser->parse('() -> Void ![DB<A | B -> C>]');
    ok $func->is_func, 'parsed as func';
    my $row = $func->effects;
    my $st = $row->label_state('DB');
    is_deeply $st->{from}, ['A', 'B'], 'from is [A, B]';
    is_deeply $st->{to}, ['C'], 'to is [C]';
    like $row->to_string, qr/DB<A \| B -> C>/, 'to_string shows set syntax';
};

subtest 'parser — ![Effect<A | B>] (invariant set)' => sub {
    my $func = Typist::Parser->parse('() -> Void ![DB<A | B>]');
    my $row = $func->effects;
    my $st = $row->label_state('DB');
    is_deeply $st->{from}, ['A', 'B'], 'from is [A, B]';
    is_deeply $st->{to}, ['A', 'B'], 'to equals from (invariant)';
    like $row->to_string, qr/DB<A \| B>/, 'to_string shows set invariant';
};

# ── Parser: parse_row with * and | ───────────────

subtest 'parse_row — * state (ground)' => sub {
    my $row = Typist::Parser->parse_row('DB<* -> *>');
    my $st = $row->label_state('DB');
    is_deeply $st->{from}, ['*'], 'from is [*]';
    is_deeply $st->{to}, ['*'], 'to is [*]';
};

subtest 'parse_row — | state set' => sub {
    my $row = Typist::Parser->parse_row('DB<A | B -> C | D>');
    my $st = $row->label_state('DB');
    is_deeply $st->{from}, ['A', 'B'], 'from is [A, B]';
    is_deeply $st->{to}, ['C', 'D'], 'to is [C, D]';
};

# ── Row: set-based equals ────────────────────────

subtest 'Row equals — set comparison' => sub {
    my $r1 = Typist::Type::Row->new(
        labels => ['DB'],
        label_states => +{ DB => { from => ['A', 'B'], to => ['C'] } },
    );
    my $r2 = Typist::Type::Row->new(
        labels => ['DB'],
        label_states => +{ DB => { from => ['B', 'A'], to => ['C'] } },
    );
    ok $r1->equals($r2), 'equals ignores order in state sets';
};

subtest 'Row to_string — set display' => sub {
    my $r = Typist::Type::Row->new(
        labels => ['DB'],
        label_states => +{ DB => { from => ['A', 'B'], to => ['C'] } },
    );
    like $r->to_string, qr/DB<A \| B -> C>/, 'set display with |';
};

subtest 'Row to_string — * invariant (ground)' => sub {
    my $r = Typist::Type::Row->new(
        labels => ['DB'],
        label_states => +{ DB => { from => ['*'], to => ['*'] } },
    );
    like $r->to_string, qr/DB<\*>/, '* invariant shows as DB<*>';
};

done_testing;
