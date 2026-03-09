use v5.40;
use Test::More;
use lib 'lib';

use Typist::Effect;
use Typist::Type::Row;
use Typist::Type::Eff;
use Typist::Kind;
use Typist::KindChecker;

# ── Effect Definition ────────────────────────────

subtest 'Effect definition' => sub {
    my $eff = Typist::Effect->new(
        name       => 'Console',
        operations => +{
            readLine  => 'CodeRef[-> Str]',
            writeLine => 'CodeRef[Str -> Void]',
        },
    );

    is $eff->name, 'Console', 'name';
    is_deeply [sort $eff->op_names], [qw(readLine writeLine)], 'op_names';
    is $eff->get_op('readLine'), 'CodeRef[-> Str]', 'get_op';
    ok !$eff->get_op('missing'), 'get_op missing returns undef';
};

# ── Row Type ─────────────────────────────────────

subtest 'Row construction and normalization' => sub {
    my $row = Typist::Type::Row->new(
        labels => [qw(State Console State)],
    );
    is_deeply [$row->labels], [qw(Console State)], 'sorted and deduped';
    ok $row->is_closed, 'no row_var means closed';
    ok !$row->is_empty, 'has labels';
    ok $row->is_row,    'is_row predicate';
};

subtest 'Row with row variable (open)' => sub {
    my $row = Typist::Type::Row->new(
        labels  => [qw(Console)],
        row_var => 'r',
    );
    ok !$row->is_closed, 'open row';
    is $row->row_var, 'r', 'row_var accessor';
    is $row->to_string, 'Console, r', 'to_string';
};

subtest 'Empty row' => sub {
    my $row = Typist::Type::Row->new;
    ok $row->is_empty,  'empty';
    ok $row->is_closed, 'closed';
    is $row->to_string, '', 'empty string';
};

subtest 'Row equality' => sub {
    my $a = Typist::Type::Row->new(labels => [qw(A B)]);
    my $b = Typist::Type::Row->new(labels => [qw(B A)]);
    ok $a->equals($b), 'order-independent equality';

    my $c = Typist::Type::Row->new(labels => [qw(A B)], row_var => 'r');
    my $d = Typist::Type::Row->new(labels => [qw(A B)], row_var => 'r');
    ok $c->equals($d), 'equality with same row_var';

    ok !$a->equals($c), 'closed != open';
};

subtest 'Row contains (phantom)' => sub {
    my $row = Typist::Type::Row->new(labels => [qw(Console)]);
    ok $row->contains(42),    'contains int';
    ok $row->contains(undef), 'contains undef';
    ok $row->contains("foo"), 'contains string';
};

subtest 'Row free_vars' => sub {
    my $closed = Typist::Type::Row->new(labels => [qw(A)]);
    is_deeply [$closed->free_vars], [], 'closed row has no free vars';

    my $open = Typist::Type::Row->new(labels => [qw(A)], row_var => 'r');
    is_deeply [$open->free_vars], ['r'], 'open row reports row_var';
};

subtest 'Row substitute' => sub {
    my $open = Typist::Type::Row->new(
        labels  => [qw(Console)],
        row_var => 'r',
    );

    # Substitute with a closed row
    my $tail = Typist::Type::Row->new(labels => [qw(State)]);
    my $result = $open->substitute(+{ r => $tail });
    is_deeply [$result->labels], [qw(Console State)], 'merged labels';
    ok $result->is_closed, 'result is closed after substituting closed tail';

    # Substitute with an open row
    my $tail2 = Typist::Type::Row->new(labels => [qw(Log)], row_var => 's');
    my $result2 = $open->substitute(+{ r => $tail2 });
    is_deeply [$result2->labels], [qw(Console Log)], 'merged labels with open tail';
    is $result2->row_var, 's', 'inherited tail variable';

    # No binding — unchanged
    my $same = $open->substitute(+{});
    ok $same->equals($open), 'no binding means no change';
};

# ── Eff Type ─────────────────────────────────────

subtest 'Eff wrapper' => sub {
    my $row = Typist::Type::Row->new(labels => [qw(Console State)]);
    my $eff = Typist::Type::Eff->new($row);

    ok $eff->is_eff, 'is_eff predicate';
    is $eff->to_string, '[Console, State]', 'to_string';
    ok $eff->contains(42), 'phantom contains';
    is_deeply [$eff->free_vars], [], 'no free vars in closed eff';
};

subtest 'Eff equality' => sub {
    my $a = Typist::Type::Eff->new(Typist::Type::Row->new(labels => [qw(A B)]));
    my $b = Typist::Type::Eff->new(Typist::Type::Row->new(labels => [qw(B A)]));
    ok $a->equals($b), 'order-independent equality';

    my $c = Typist::Type::Eff->new(Typist::Type::Row->new(labels => [qw(A)]));
    ok !$a->equals($c), 'different labels';
};

subtest 'Eff substitute delegates to Row' => sub {
    my $eff = Typist::Type::Eff->new(
        Typist::Type::Row->new(labels => [qw(Console)], row_var => 'r'),
    );
    my $tail = Typist::Type::Row->new(labels => [qw(State)]);
    my $result = $eff->substitute(+{ r => $tail });

    ok $result->is_eff, 'still Eff';
    is $result->to_string, '[Console, State]', 'substituted';
};

# ── Kind System ──────────────────────────────────

subtest 'Kind::Row' => sub {
    my $row_kind = Typist::Kind->Row;
    is $row_kind->to_string, 'Row', 'to_string';
    ok $row_kind->equals(Typist::Kind->Row), 'singleton equality';
    ok !$row_kind->equals(Typist::Kind->Star), 'Row != Star';
    is $row_kind->arity, 0, 'arity 0';
};

subtest 'Kind parsing with Row' => sub {
    my $k = Typist::Kind->parse('Row');
    ok $k->equals(Typist::Kind->Row), 'parse Row';

    my $arrow = Typist::Kind->parse('Row -> *');
    ok $arrow->equals(Typist::Kind->Arrow(Typist::Kind->Row, Typist::Kind->Star)),
       'parse Row -> *';
};

subtest 'KindChecker infer_kind for Row and Eff' => sub {
    my $row = Typist::Type::Row->new(labels => [qw(Console)]);
    my $eff = Typist::Type::Eff->new($row);

    ok Typist::KindChecker->infer_kind($row)->equals(Typist::Kind->Row), 'Row kind';
    ok Typist::KindChecker->infer_kind($eff)->equals(Typist::Kind->Row), 'Eff kind';
};

# ── Predicate checks on base Type ────────────────

subtest 'Type predicates default to 0' => sub {
    use Typist::Type::Atom;
    my $atom = Typist::Type::Atom->new('Int');
    ok !$atom->is_row, 'Atom is not row';
    ok !$atom->is_eff, 'Atom is not eff';
};

done_testing;
