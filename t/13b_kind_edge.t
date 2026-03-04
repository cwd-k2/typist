use v5.40;
use Test::More;
use lib 'lib';
use Typist::Kind;
use Typist::KindChecker;
use Typist::Parser;

# ── Kind constructors and equality ──────────────

subtest 'Kind singletons' => sub {
    my $s1 = Typist::Kind->Star;
    my $s2 = Typist::Kind->Star;
    ok $s1->equals($s2), 'Star is singleton';
    is $s1->to_string, '*', 'Star to_string';
    is $s1->arity, 0, 'Star arity is 0';

    my $r1 = Typist::Kind->Row;
    my $r2 = Typist::Kind->Row;
    ok $r1->equals($r2), 'Row is singleton';
    is $r1->to_string, 'Row', 'Row to_string';
    ok !$r1->equals($s1), 'Row != Star';
};

subtest 'Arrow kind' => sub {
    my $star = Typist::Kind->Star;
    my $arrow = Typist::Kind->Arrow($star, $star);
    is $arrow->to_string, '* -> *', 'simple arrow to_string';
    is $arrow->arity, 1, 'arity of * -> * is 1';
    ok $arrow->from->equals($star), 'from is Star';
    ok $arrow->to->equals($star), 'to is Star';
};

# ── Nested arrow kinds ──────────────────────────

subtest 'nested arrow kinds' => sub {
    my $star = Typist::Kind->Star;
    # * -> * -> * (right-associative)
    my $k = Typist::Kind->Arrow($star, Typist::Kind->Arrow($star, $star));
    is $k->to_string, '* -> * -> *', 'nested arrow to_string';
    is $k->arity, 2, 'arity of * -> * -> * is 2';

    # (* -> *) -> * (left-nested)
    my $left = Typist::Kind->Arrow(
        Typist::Kind->Arrow($star, $star),
        $star,
    );
    is $left->to_string, '(* -> *) -> *', 'left-nested arrow parenthesized';
    is $left->arity, 1, 'arity of (* -> *) -> * is 1';
};

# ── Kind parsing ────────────────────────────────

subtest 'Kind::parse basics' => sub {
    my $star = Typist::Kind->parse('*');
    ok $star->equals(Typist::Kind->Star), 'parse "*" = Star';

    my $row = Typist::Kind->parse('Row');
    ok $row->equals(Typist::Kind->Row), 'parse "Row" = Row';

    my $arrow = Typist::Kind->parse('* -> *');
    is $arrow->to_string, '* -> *', 'parse "* -> *"';

    my $nested = Typist::Kind->parse('* -> * -> *');
    is $nested->to_string, '* -> * -> *', 'parse "* -> * -> *" (right-assoc)';
};

subtest 'Kind::parse with Row' => sub {
    my $k = Typist::Kind->parse('Row -> *');
    is $k->to_string, 'Row -> *', 'parse "Row -> *"';
    ok $k->from->equals(Typist::Kind->Row), 'from is Row';
    ok $k->to->equals(Typist::Kind->Star), 'to is Star';
};

subtest 'Kind::parse error on invalid token' => sub {
    eval { Typist::Kind->parse('Foo') };
    ok $@, 'invalid kind token dies';
    like $@, qr/expected|Foo/, 'meaningful error';
};

# ── KindChecker: built-in constructors ──────────

subtest 'built-in constructor kinds' => sub {
    my $arr = Typist::KindChecker->constructor_kind('ArrayRef');
    ok $arr, 'ArrayRef has a kind';
    is $arr->to_string, '* -> *', 'ArrayRef : * -> *';

    my $hash = Typist::KindChecker->constructor_kind('HashRef');
    is $hash->to_string, '* -> * -> *', 'HashRef : * -> * -> *';

    my $maybe = Typist::KindChecker->constructor_kind('Maybe');
    is $maybe->to_string, '* -> *', 'Maybe : * -> *';

    my $unknown = Typist::KindChecker->constructor_kind('Foo');
    ok !defined $unknown, 'unknown constructor returns undef';
};

# ── KindChecker: check_application ──────────────

subtest 'check_application valid' => sub {
    my $star = Typist::Kind->Star;
    my $result = Typist::KindChecker->check_application('ArrayRef', $star);
    ok $result->equals($star), 'ArrayRef[*] = *';

    my $partial = Typist::KindChecker->check_application('HashRef', $star);
    is $partial->to_string, '* -> *', 'HashRef[*] = * -> * (partially applied)';

    my $full = Typist::KindChecker->check_application('HashRef', $star, $star);
    ok $full->equals($star), 'HashRef[*, *] = *';
};

subtest 'check_application excess args' => sub {
    my $star = Typist::Kind->Star;
    eval { Typist::KindChecker->check_application('ArrayRef', $star, $star) };
    ok $@, 'excess args die';
    like $@, qr/too many/, 'error mentions too many';
};

subtest 'check_application kind mismatch' => sub {
    my $row = Typist::Kind->Row;
    eval { Typist::KindChecker->check_application('ArrayRef', $row) };
    ok $@, 'kind mismatch dies';
    like $@, qr/kind.*Row.*expected.*\*|argument/i, 'error mentions kind mismatch';
};

# ── KindChecker: infer_kind ────────────────────

subtest 'infer_kind atoms' => sub {
    my $int = Typist::Parser->parse('Int');
    my $k = Typist::KindChecker->infer_kind($int);
    ok $k->equals(Typist::Kind->Star), 'Int : *';
};

subtest 'infer_kind Row type' => sub {
    require Typist::Type::Row;
    my $row = Typist::Type::Row->new(labels => ['IO']);
    my $k = Typist::KindChecker->infer_kind($row);
    ok $k->equals(Typist::Kind->Row), 'Row type has kind Row';
};

subtest 'infer_kind parameterized' => sub {
    my $arr_int = Typist::Parser->parse('ArrayRef[Int]');
    my $k = Typist::KindChecker->infer_kind($arr_int);
    ok $k->equals(Typist::Kind->Star), 'ArrayRef[Int] : *';
};

subtest 'infer_kind type variable with kind' => sub {
    require Typist::Type::Var;
    my $f = Typist::Type::Var->new('F');
    my $star = Typist::Kind->Star;
    my $arrow = Typist::Kind->Arrow($star, $star);
    my $k = Typist::KindChecker->infer_kind($f, +{ F => $arrow });
    ok $k->equals($arrow), 'F inferred as * -> * from var_kinds';
};

subtest 'infer_kind HKT application' => sub {
    # F[A] where F: * -> *, A: *
    require Typist::Type::Var;
    require Typist::Type::Param;
    my $f = Typist::Type::Var->new('F');
    my $a = Typist::Type::Var->new('A');
    my $fa = Typist::Type::Param->new($f, $a);

    my $star = Typist::Kind->Star;
    my $arrow = Typist::Kind->Arrow($star, $star);
    my $k = Typist::KindChecker->infer_kind($fa, +{ F => $arrow, A => $star });
    ok $k->equals($star), 'F[A] : * when F : * -> *, A : *';
};

subtest 'infer_kind function' => sub {
    my $func = Typist::Parser->parse('(Int) -> Str');
    my $k = Typist::KindChecker->infer_kind($func);
    ok $k->equals(Typist::Kind->Star), 'function types are *';
};

subtest 'infer_kind union members must be *' => sub {
    my $union = Typist::Parser->parse('Int | Str');
    my $k = Typist::KindChecker->infer_kind($union);
    ok $k->equals(Typist::Kind->Star), 'union of atoms is *';
};

subtest 'infer_kind literal' => sub {
    require Typist::Type::Literal;
    my $lit = Typist::Type::Literal->new(42, 'Int');
    my $k = Typist::KindChecker->infer_kind($lit);
    ok $k->equals(Typist::Kind->Star), 'literal is *';
};

subtest 'infer_kind record' => sub {
    my $rec = Typist::Parser->parse('{ x => Int }');
    my $k = Typist::KindChecker->infer_kind($rec);
    ok $k->equals(Typist::Kind->Star), 'record is *';
};

# ── Register custom kind ───────────────────────

subtest 'register_kind custom constructor' => sub {
    my $star = Typist::Kind->Star;
    Typist::KindChecker->register_kind('MyFunctor',
        Typist::Kind->Arrow($star, $star));

    my $k = Typist::KindChecker->constructor_kind('MyFunctor');
    ok $k, 'custom constructor registered';
    is $k->to_string, '* -> *', 'MyFunctor : * -> *';

    my $result = Typist::KindChecker->check_application('MyFunctor', $star);
    ok $result->equals($star), 'MyFunctor[*] = *';

    # Clean up: reset to built-in defaults to avoid test leaks
    Typist::KindChecker->reset_kinds;
    ok !defined Typist::KindChecker->constructor_kind('MyFunctor'),
        'MyFunctor removed after reset_kinds';
};

done_testing;
