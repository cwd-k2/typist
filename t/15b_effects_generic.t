use v5.40;
use Test::More;

use Typist::Parser;
use Typist::Effect;
use Typist::Type::Row;
use Typist::Registry;

# ── Parser: parameterized effect labels ──────────

subtest 'parse: ![State[Int]]' => sub {
    my $type = Typist::Parser->parse('(Int) -> Void ![State[Int]]');
    ok $type->is_func, 'is_func';
    my $row = $type->effects;
    ok $row, 'has effects';
    ok $row->is_row, 'effects is Row';
    is_deeply [$row->labels], ['State[Int]'], 'label = State[Int]';
    ok $row->is_closed, 'closed row';
};

subtest 'parse: ![State[Int], Console, r]' => sub {
    my $type = Typist::Parser->parse('(Int) -> Void ![State[Int], Console, r]');
    my $row = $type->effects;
    is_deeply [$row->labels], ['Console', 'State[Int]'], 'labels sorted';
    is $row->row_var_name, 'r', 'row_var = r';
};

subtest 'parse_row: State[Int]' => sub {
    my $row = Typist::Parser->parse_row('State[Int], Console');
    is_deeply [$row->labels], ['Console', 'State[Int]'], 'parameterized label in parse_row';
};

subtest 'parse_row: State[Int] with protocol state' => sub {
    my $row = Typist::Parser->parse_row('State[Int]<Running>');
    is_deeply [$row->labels], ['State[Int]'], 'parameterized + protocol';
    my $st = $row->label_state('State[Int]');
    ok $st, 'has label_state';
    is_deeply $st->{from}, ['Running'], 'from state';
    is_deeply $st->{to}, ['Running'], 'to state';
};

subtest 'parse: nested params ![State[Pair[Int, Str]]]' => sub {
    my $type = Typist::Parser->parse('() -> Void ![State[Pair[Int, Str]]]');
    my $row = $type->effects;
    is_deeply [$row->labels], ['State[Pair[Int, Str]]'], 'nested param label';
};

# ── Row: label_base_name ────────────────────────

subtest 'label_base_name' => sub {
    is Typist::Type::Row->label_base_name('Console'), 'Console', 'plain label';
    is Typist::Type::Row->label_base_name('State[Int]'), 'State', 'parameterized';
    is Typist::Type::Row->label_base_name('State[Pair[A, B]]'), 'State', 'nested';
};

# ── Effect: type_params ─────────────────────────

subtest 'Effect type_params and is_generic' => sub {
    my $eff = Typist::Effect->new(
        name        => 'State',
        operations  => +{ get => '() -> S', put => '(S) -> Void' },
        type_params => ['S'],
    );
    is_deeply [$eff->type_params], ['S'], 'type_params';
    ok $eff->is_generic, 'is_generic';

    my $plain = Typist::Effect->new(
        name       => 'Console',
        operations => +{ log => '(Str) -> Void' },
    );
    ok !$plain->is_generic, 'not generic';
};

# ── Row subtyping with parameterized labels ─────

subtest 'Row subtype: parameterized labels' => sub {
    require Typist::Subtype;

    my $specific = Typist::Type::Row->new(labels => ['Console', 'State[Int]']);
    my $broader  = Typist::Type::Row->new(labels => ['State[Int]']);
    my $wrong    = Typist::Type::Row->new(labels => ['State[Str]']);

    ok  Typist::Subtype->is_subtype($specific, $broader),
        '{Console, State[Int]} <: {State[Int]}';
    ok !Typist::Subtype->is_subtype($broader, $specific),
        '{State[Int]} </: {Console, State[Int]}';
    ok !Typist::Subtype->is_subtype($specific, $wrong),
        '{Console, State[Int]} </: {State[Str]} — different param';
};

# ── Row equality ────────────────────────────────

subtest 'Row equals: parameterized labels' => sub {
    my $a = Typist::Type::Row->new(labels => ['State[Int]', 'Console']);
    my $b = Typist::Type::Row->new(labels => ['Console', 'State[Int]']);
    my $c = Typist::Type::Row->new(labels => ['Console', 'State[Str]']);

    ok  $a->equals($b), 'same labels, different order';
    ok !$a->equals($c), 'different type param';
};

# ── Row to_string ───────────────────────────────

subtest 'Row to_string: parameterized' => sub {
    my $row = Typist::Type::Row->new(labels => ['Console', 'State[Int]']);
    is $row->to_string, 'Console, State[Int]', 'to_string';
};

done_testing;
