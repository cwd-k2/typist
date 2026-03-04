use v5.40;
use Test::More;

use Typist::Parser;
use Typist::Registry;
use Typist::Subtype;
use Typist::Inference;
use Typist::Effect;
use Typist::Type::Row;
use Typist::Type::Eff;

# ── parse_row ────────────────────────────────────

subtest 'parse_row: closed row' => sub {
    my $row = Typist::Parser->parse_row('Console, State');
    ok $row->is_row, 'is_row';
    is_deeply [$row->labels], [qw(Console State)], 'labels sorted';
    ok $row->is_closed, 'closed';
};

subtest 'parse_row: open row' => sub {
    my $row = Typist::Parser->parse_row('Console, r');
    is_deeply [$row->labels], [qw(Console)], 'labels';
    is $row->row_var, 'r', 'row_var';
    ok !$row->is_closed, 'open';
};

subtest 'parse_row: single label' => sub {
    my $row = Typist::Parser->parse_row('IO');
    is_deeply [$row->labels], [qw(IO)], 'single label';
    ok $row->is_closed, 'closed';
};

subtest 'parse_row: only row_var' => sub {
    my $row = Typist::Parser->parse_row('r');
    is_deeply [$row->labels], [], 'no labels';
    is $row->row_var, 'r', 'row_var only';
};

subtest 'parse_row: row_var must be last' => sub {
    eval { Typist::Parser->parse_row('r, Console') };
    like $@, qr/row variable.*must be the last/, 'row_var not last raises error';
};

# ── Registry effects ─────────────────────────────

subtest 'Registry effect management' => sub {
    Typist::Registry->reset;

    my $eff = Typist::Effect->new(
        name       => 'Console',
        operations => +{ readLine => 'CodeRef[-> Str]' },
    );
    Typist::Registry->register_effect('Console', $eff);

    ok Typist::Registry->is_effect_label('Console'), 'is_effect_label';
    ok !Typist::Registry->is_effect_label('Unknown'), 'unknown is not effect';

    my $looked = Typist::Registry->lookup_effect('Console');
    is $looked->name, 'Console', 'lookup_effect';

    my %all = Typist::Registry->all_effects;
    is_deeply [sort keys %all], ['Console'], 'all_effects';

    Typist::Registry->reset;
};

# ── Row Subtyping ────────────────────────────────

subtest 'Row subtype: label inclusion' => sub {
    my $abc = Typist::Type::Row->new(labels => [qw(A B C)]);
    my $ab  = Typist::Type::Row->new(labels => [qw(A B)]);
    my $a   = Typist::Type::Row->new(labels => [qw(A)]);
    my $d   = Typist::Type::Row->new(labels => [qw(D)]);

    ok  Typist::Subtype->is_subtype($abc, $ab), '{A,B,C} <: {A,B}';
    ok  Typist::Subtype->is_subtype($abc, $a),  '{A,B,C} <: {A}';
    ok !Typist::Subtype->is_subtype($ab, $abc), '{A,B} </: {A,B,C}';
    ok !Typist::Subtype->is_subtype($ab, $d),   '{A,B} </: {D}';
};

subtest 'Row subtype: empty row is supertype of all' => sub {
    my $abc   = Typist::Type::Row->new(labels => [qw(A B C)]);
    my $empty = Typist::Type::Row->new;

    ok Typist::Subtype->is_subtype($abc, $empty), '{A,B,C} <: {}';
    ok Typist::Subtype->is_subtype($empty, $empty), '{} <: {}';
};

subtest 'Eff subtype delegates to Row' => sub {
    my $eff_abc = Typist::Type::Eff->new(Typist::Type::Row->new(labels => [qw(A B C)]));
    my $eff_ab  = Typist::Type::Eff->new(Typist::Type::Row->new(labels => [qw(A B)]));

    ok  Typist::Subtype->is_subtype($eff_abc, $eff_ab), '[A,B,C] <: [A,B]';
    ok !Typist::Subtype->is_subtype($eff_ab, $eff_abc), '[A,B] </: [A,B,C]';
};

# ── Row Unification ──────────────────────────────

subtest 'unify: concrete rows' => sub {
    my $formal = Typist::Type::Row->new(labels => [qw(Console)], row_var => 'r');
    my $actual = Typist::Type::Row->new(labels => [qw(Console State)]);

    my %bindings;
    # Access _unify through instantiate by constructing Eff wrappers
    Typist::Inference::_unify(
        Typist::Type::Eff->new($formal),
        Typist::Type::Eff->new($actual),
        \%bindings,
    );

    ok exists $bindings{r}, 'r is bound';
    ok $bindings{r}->is_row, 'bound to Row';
    is_deeply [$bindings{r}->labels], [qw(State)], 'r bound to excess labels';
    ok $bindings{r}->is_closed, 'bound row is closed';
};

subtest 'unify: two open rows' => sub {
    my $formal = Typist::Type::Row->new(labels => [qw(Console)], row_var => 'r');
    my $actual = Typist::Type::Row->new(labels => [qw(Console State)], row_var => 's');

    my %bindings;
    Typist::Inference::_unify_rows($formal, $actual, \%bindings);

    ok exists $bindings{r}, 'r is bound';
    is_deeply [$bindings{r}->labels], [qw(State)], 'r gets State';
    is $bindings{r}->row_var, 's', 'r inherits s as tail';

    ok exists $bindings{s}, 's is bound';
    is_deeply [$bindings{s}->labels], [], 's gets no excess';
    is $bindings{s}->row_var, 'r', 's inherits r as tail';
};

subtest 'unify: matching rows yield empty bindings' => sub {
    my $formal = Typist::Type::Row->new(labels => [qw(A B)]);
    my $actual = Typist::Type::Row->new(labels => [qw(A B)]);

    my %bindings;
    Typist::Inference::_unify_rows($formal, $actual, \%bindings);

    is scalar(keys %bindings), 0, 'no bindings needed';
};

# ── Row::substitute with non-Row binding ────────

subtest 'substitute: non-Row binding closes the row' => sub {
    my $row = Typist::Type::Row->new(
        labels  => ['Console'],
        row_var => 'r',
    );
    my $result = $row->substitute({ r => Typist::Type::Atom->new('Int') });
    ok $result->is_row, 'result is row';
    ok $result->is_closed, 'row_var removed (closed)';
    is_deeply [$result->labels], ['Console'], 'labels preserved';
};

done_testing;
