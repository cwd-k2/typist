use v5.40;
use Test::More;
use lib 'lib';

use Typist::Type::Quantified;
use Typist::Type::Func;
use Typist::Type::Atom;
use Typist::Type::Var;
use Typist::Type::Param;
use Typist::Parser;
use Typist::Subtype;
use Typist::Type::Fold;
use Typist::Static::Unify;

# ── Construction ───────────────────────────────

subtest 'Quantified: basic construction' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'A' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('A'),
        ),
    );

    ok $q->is_quantified, 'is_quantified predicate';
    is $q->name, 'forall A. (A) -> A', 'name delegates to to_string';
    is scalar($q->vars), 1, 'one var';
    ok $q->body->is_func, 'body is Func';
};

subtest 'Quantified: multi-var construction' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'A' }, { name => 'B' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('B'),
        ),
    );

    is scalar($q->vars), 2, 'two vars';
};

subtest 'Quantified: with bound' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'A', bound => Typist::Type::Atom->new('Num') }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('A'),
        ),
    );

    my @vars = $q->vars;
    ok $vars[0]{bound}, 'var has bound';
    is $vars[0]{bound}->name, 'Num', 'bound is Num';
};

# ── to_string ──────────────────────────────────

subtest 'to_string: simple' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'A' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('A'),
        ),
    );

    is $q->to_string, 'forall A. (A) -> A', 'forall A. (A) -> A';
};

subtest 'to_string: multi-var' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'A' }, { name => 'B' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A'), Typist::Type::Var->new('B')],
            Typist::Type::Var->new('A'),
        ),
    );

    is $q->to_string, 'forall A B. (A, B) -> A', 'forall A B. (A, B) -> A';
};

subtest 'to_string: with bound' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'A', bound => Typist::Type::Atom->new('Num') }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('A'),
        ),
    );

    is $q->to_string, 'forall A: Num. (A) -> A', 'bound shown in to_string';
};

# ── equals ─────────────────────────────────────

subtest 'equals: identical' => sub {
    my $mk = sub {
        Typist::Type::Quantified->new(
            vars => [{ name => 'A' }],
            body => Typist::Type::Func->new(
                [Typist::Type::Var->new('A')],
                Typist::Type::Var->new('A'),
            ),
        );
    };

    ok $mk->()->equals($mk->()), 'equal quantified types';
};

subtest 'equals: different vars' => sub {
    my $q1 = Typist::Type::Quantified->new(
        vars => [{ name => 'A' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('A'),
        ),
    );
    my $q2 = Typist::Type::Quantified->new(
        vars => [{ name => 'B' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('B')],
            Typist::Type::Var->new('B'),
        ),
    );

    ok !$q1->equals($q2), 'different var names are not equal';
};

# ── free_vars ──────────────────────────────────

subtest 'free_vars: bound vars excluded' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'A' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('A'),
        ),
    );

    is_deeply [sort $q->free_vars], [], 'no free vars (A is bound)';
};

subtest 'free_vars: unbound vars remain' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'A' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('B'),
        ),
    );

    is_deeply [sort $q->free_vars], ['B'], 'B is free';
};

# ── substitute ─────────────────────────────────

subtest 'substitute: bound vars not replaced' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'A' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('A'),
        ),
    );

    my $result = $q->substitute(+{ A => Typist::Type::Atom->new('Int') });
    ok $result->is_quantified, 'still quantified after substitute';
    ok $result->body->returns->is_var, 'A in body not replaced (bound)';
};

subtest 'substitute: free vars replaced' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'A' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('B'),
        ),
    );

    my $result = $q->substitute(+{ B => Typist::Type::Atom->new('Str') });
    ok $result->body->returns->is_atom, 'B replaced with Str';
    is $result->body->returns->name, 'Str', 'correct replacement';
};

# ── Parser ─────────────────────────────────────

subtest 'Parser: forall A. A -> A' => sub {
    my $t = Typist::Parser->parse('forall A. A -> A');
    ok $t->is_quantified, 'parsed as Quantified';
    is scalar($t->vars), 1, 'one var';
    is(($t->vars)[0]->{name}, 'A', 'var name is A');
    ok $t->body->is_func, 'body is Func';
};

subtest 'Parser: forall A B. (A, B) -> A' => sub {
    my $t = Typist::Parser->parse('forall A B. (A, B) -> A');
    ok $t->is_quantified, 'parsed as Quantified';
    is scalar($t->vars), 2, 'two vars';
    is(($t->vars)[0]->{name}, 'A', 'first var is A');
    is(($t->vars)[1]->{name}, 'B', 'second var is B');
    ok $t->body->is_func, 'body is Func';
    is scalar($t->body->params), 2, 'body has two params';
};

subtest 'Parser: forall with bound' => sub {
    my $t = Typist::Parser->parse('forall A: Num. A -> A');
    ok $t->is_quantified, 'parsed as Quantified';
    my @vars = $t->vars;
    ok $vars[0]{bound}, 'has bound';
    is $vars[0]{bound}->name, 'Num', 'bound is Num';
};

subtest 'Parser: forall inside parentheses (rank-2 param)' => sub {
    my $t = Typist::Parser->parse('(forall A. A -> A, Int) -> Int');
    ok $t->is_func, 'outer is Func';
    my @params = $t->params;
    is scalar @params, 2, 'two params';
    ok $params[0]->is_quantified, 'first param is Quantified';
    ok $params[1]->is_atom && $params[1]->name eq 'Int', 'second param is Int';
    ok $t->returns->is_atom && $t->returns->name eq 'Int', 'returns Int';
};

subtest 'Parser: forall with grouped body' => sub {
    my $t = Typist::Parser->parse('forall A. (A, A) -> A');
    ok $t->is_quantified, 'parsed as Quantified';
    ok $t->body->is_func, 'body is Func';
    is scalar($t->body->params), 2, 'body has two params';
};

# ── Subtype ────────────────────────────────────

subtest 'Subtype: Quantified <: Concrete (instantiation)' => sub {
    my $q = Typist::Parser->parse('forall A. A -> A');
    my $c = Typist::Parser->parse('(Int) -> Int');

    ok Typist::Subtype->is_subtype($q, $c),
        '(forall A. A -> A) <: (Int -> Int)';
};

subtest 'Subtype: Concrete NOT <: Quantified' => sub {
    my $q = Typist::Parser->parse('forall A. A -> A');
    my $c = Typist::Parser->parse('(Int) -> Int');

    ok !Typist::Subtype->is_subtype($c, $q),
        '(Int -> Int) ≮: (forall A. A -> A)';
};

subtest 'Subtype: Quantified <: Quantified (same structure)' => sub {
    my $q1 = Typist::Parser->parse('forall A. A -> A');
    my $q2 = Typist::Parser->parse('forall A. A -> A');

    ok Typist::Subtype->is_subtype($q1, $q2),
        'identical quantified types are subtypes';
};

subtest 'Subtype: Quantified instantiation mismatch' => sub {
    my $q = Typist::Parser->parse('forall A. A -> A');
    my $c = Typist::Parser->parse('(Int) -> Str');

    ok !Typist::Subtype->is_subtype($q, $c),
        '(forall A. A -> A) ≮: (Int -> Str) — return type mismatch';
};

subtest 'Subtype: Quantified <: Concrete with complex types' => sub {
    my $q = Typist::Parser->parse('forall A. (A) -> ArrayRef[A]');
    my $c = Typist::Parser->parse('(Int) -> ArrayRef[Int]');

    ok Typist::Subtype->is_subtype($q, $c),
        '(forall A. A -> ArrayRef[A]) <: (Int -> ArrayRef[Int])';
};

# ── Fold ───────────────────────────────────────

subtest 'Fold: walk visits Quantified body' => sub {
    my $q = Typist::Parser->parse('forall A. A -> A');
    my @visited;
    Typist::Type::Fold->walk($q, sub ($t) { push @visited, ref $t });

    ok scalar @visited > 1, 'walk visits multiple nodes';
    is $visited[0], 'Typist::Type::Quantified', 'first visited is Quantified';
};

subtest 'Fold: map_type rebuilds Quantified' => sub {
    my $q = Typist::Parser->parse('forall A. A -> A');
    my $mapped = Typist::Type::Fold->map_type($q, sub ($t) { $t });

    ok $mapped->is_quantified, 'mapped type is still Quantified';
    is $mapped->to_string, $q->to_string, 'structure preserved';
};

# ── Gradual Typing + Rank-2 ───────────────────

subtest 'Subtype: gradual (Any) -> Any NOT <: forall A. (A) -> A' => sub {
    my $gradual = Typist::Parser->parse('(Any) -> Any');
    my $q       = Typist::Parser->parse('forall A. A -> A');

    ok !Typist::Subtype->is_subtype($gradual, $q),
        '(Any) -> Any ≮: (forall A. A -> A) — mono cannot satisfy forall';
};

subtest 'Subtype: concrete still NOT <: forall' => sub {
    my $c = Typist::Parser->parse('(Str) -> Str');
    my $q = Typist::Parser->parse('forall A. A -> A');

    ok !Typist::Subtype->is_subtype($c, $q),
        '(Str) -> Str ≮: (forall A. A -> A) — still rejected';
};

subtest 'Subtype: Any atom NOT <: forall' => sub {
    my $any = Typist::Type::Atom->new('Any');
    my $q   = Typist::Parser->parse('forall A. A -> A');

    ok !Typist::Subtype->is_subtype($any, $q),
        'Any ≮: (forall A. A -> A) — mono cannot satisfy forall';
};

# ── collect_bindings: Quantified ──────────────

subtest 'collect_bindings: both Quantified with HKT' => sub {
    # formal: forall R. ((A) -> F[R]) -> F[R]
    # actual: forall R. ((A) -> ArrayRef[R]) -> ArrayRef[R]
    # Should bind F => ArrayRef, A stays free (already bound outside)
    my $formal = Typist::Parser->parse('forall R. ((A) -> F[R]) -> F[R]');
    my $actual = Typist::Parser->parse('forall R. ((A) -> ArrayRef[R]) -> ArrayRef[R]');
    my %bindings;
    my $ok = Typist::Static::Unify->collect_bindings($formal, $actual, \%bindings);
    ok $ok, 'both-quantified collect_bindings succeeds';
    ok exists $bindings{F}, 'F is bound';
    is $bindings{F}->name, 'ArrayRef', 'F => ArrayRef';
};

subtest 'collect_bindings: both Quantified same var names' => sub {
    my $formal = Typist::Parser->parse('forall A. (A) -> A');
    my $actual = Typist::Parser->parse('forall A. (A) -> A');
    my %bindings;
    my $ok = Typist::Static::Unify->collect_bindings($formal, $actual, \%bindings);
    ok $ok, 'identical quantified types succeed';
    # Body vars produce identity binding A => Var(A)
    ok exists $bindings{A}, 'A bound (identity)';
    is $bindings{A}->name, 'A', 'A => A';
};

subtest 'collect_bindings: both Quantified different var names' => sub {
    my $formal = Typist::Parser->parse('forall A. (A) -> A');
    my $actual = Typist::Parser->parse('forall B. (B) -> B');
    my %bindings;
    my $ok = Typist::Static::Unify->collect_bindings($formal, $actual, \%bindings);
    ok $ok, 'different var names succeed (renamed)';
};

subtest 'collect_bindings: Quantified vars count mismatch' => sub {
    my $formal = Typist::Parser->parse('forall A. (A) -> A');
    my $actual = Typist::Parser->parse('forall A B. (A, B) -> A');
    my %bindings;
    my $ok = Typist::Static::Unify->collect_bindings($formal, $actual, \%bindings);
    ok !$ok, 'vars count mismatch fails';
};

subtest 'collect_bindings: formal-only Quantified' => sub {
    my $formal = Typist::Parser->parse('forall R. (R) -> R');
    my $actual = Typist::Type::Func->new(
        [Typist::Type::Var->new('X')],
        Typist::Type::Var->new('X'),
    );
    my %bindings;
    my $ok = Typist::Static::Unify->collect_bindings($formal, $actual, \%bindings);
    ok $ok, 'formal-only Quantified succeeds';
    ok exists $bindings{R}, 'R is bound';
    is $bindings{R}->name, 'X', 'R => X';
};

subtest 'collect_bindings: actual-only Quantified' => sub {
    my $formal = Typist::Type::Func->new(
        [Typist::Type::Var->new('T')],
        Typist::Type::Var->new('T'),
    );
    my $actual = Typist::Parser->parse('forall A. (A) -> A');
    my %bindings;
    my $ok = Typist::Static::Unify->collect_bindings($formal, $actual, \%bindings);
    ok $ok, 'actual-only Quantified succeeds';
    ok exists $bindings{T}, 'T is bound';
    is $bindings{T}->name, 'A', 'T => A (from unwrapped body)';
};

done_testing;
