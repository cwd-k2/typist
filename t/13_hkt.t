use v5.40;
use Test::More;
use lib 'lib';
use Typist::Kind;
use Typist::KindChecker;
use Typist::Parser;
use Typist::Registry;
use Typist::TypeClass;
use Typist::Type::Var;

# ── Kind basics ──────────────────────────────────

subtest 'Star kind' => sub {
    my $star = Typist::Kind->Star;
    is $star->to_string, '*', 'Star to_string';
    is $star->arity, 0, 'Star arity is 0';
    ok $star->equals(Typist::Kind->Star), 'Star == Star (singleton)';
};

subtest 'Arrow kind' => sub {
    my $star = Typist::Kind->Star;
    my $arr = Typist::Kind->Arrow($star, $star);
    is $arr->to_string, '* -> *', 'Arrow to_string';
    is $arr->arity, 1, 'Arrow arity is 1';
    ok $arr->from->equals($star), 'from is Star';
    ok $arr->to->equals($star), 'to is Star';

    my $arr2 = Typist::Kind->Arrow($star, Typist::Kind->Arrow($star, $star));
    is $arr2->to_string, '* -> * -> *', 'nested Arrow to_string';
    is $arr2->arity, 2, 'nested Arrow arity is 2';
};

subtest 'kind parsing' => sub {
    my $k1 = Typist::Kind->parse('*');
    ok $k1->equals(Typist::Kind->Star), 'parse *';

    my $k2 = Typist::Kind->parse('* -> *');
    is $k2->to_string, '* -> *', 'parse * -> *';
    is $k2->arity, 1, 'arity 1';

    my $k3 = Typist::Kind->parse('* -> * -> *');
    is $k3->to_string, '* -> * -> *', 'parse * -> * -> * (right-assoc)';
    is $k3->arity, 2, 'arity 2';
};

# ── KindChecker ──────────────────────────────────

subtest 'constructor kinds' => sub {
    my $ak = Typist::KindChecker->constructor_kind('ArrayRef');
    ok $ak, 'ArrayRef has a kind';
    is $ak->to_string, '* -> *', 'ArrayRef : * -> *';

    my $hk = Typist::KindChecker->constructor_kind('HashRef');
    ok $hk, 'HashRef has a kind';
    is $hk->to_string, '* -> * -> *', 'HashRef : * -> * -> *';
};

subtest 'check application' => sub {
    my $star = Typist::Kind->Star;

    # ArrayRef[Int] — one * argument → *
    my $result = Typist::KindChecker->check_application('ArrayRef', $star);
    ok $result->equals($star), 'ArrayRef[*] = *';

    # HashRef[Str, Int] — two * arguments → *
    my $result2 = Typist::KindChecker->check_application('HashRef', $star, $star);
    ok $result2->equals($star), 'HashRef[*, *] = *';

    # ArrayRef applied to too many args
    eval { Typist::KindChecker->check_application('ArrayRef', $star, $star) };
    like $@, qr/too many/, 'ArrayRef[*, *] is kind error';
};

subtest 'infer kind of type expressions' => sub {
    my $star = Typist::Kind->Star;

    my $int_t = Typist::Parser->parse('Int');
    my $k = Typist::KindChecker->infer_kind($int_t);
    ok $k->equals($star), 'Int has kind *';

    my $arr_t = Typist::Parser->parse('ArrayRef[Int]');
    my $k2 = Typist::KindChecker->infer_kind($arr_t);
    ok $k2->equals($star), 'ArrayRef[Int] has kind *';
};

# ── HKT type variables ──────────────────────────

subtest 'var with kind' => sub {
    my $kind = Typist::Kind->parse('* -> *');
    my $v = Typist::Type::Var->new('F', kind => $kind);

    ok  $v->is_var, 'is var';
    is  $v->name, 'F', 'name';
    ok  $v->kind, 'has kind';
    is  $v->kind->to_string, '* -> *', 'kind is * -> *';
};

subtest 'infer kind with var kinds' => sub {
    my $star = Typist::Kind->Star;
    my $f_kind = Typist::Kind->parse('* -> *');

    # F type variable with kind * -> *
    my $f_var = Typist::Type::Var->new('F');
    my $inferred = Typist::KindChecker->infer_kind($f_var, +{ F => $f_kind });
    ok $inferred->equals($f_kind), 'F has kind * -> * from env';
};

# ── TypeClass with HKT ──────────────────────────

subtest 'HKT typeclass definition' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Functor',
        var     => 'F: * -> *',
        methods => +{
            fmap => 'CodeRef[CodeRef[A -> B], F[A] -> F[B]]',
        },
    );

    is $def->name, 'Functor', 'class name';
    is $def->var, 'F', 'var name extracted';
    is $def->var_kind_str, '* -> *', 'var kind string';
    is_deeply [sort $def->method_names], ['fmap'], 'methods';
};

subtest 'HKT instance (Functor for ArrayRef)' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Functor',
        var     => 'F: * -> *',
        methods => +{ fmap => 'CodeRef[CodeRef[A -> B], F[A] -> F[B]]' },
    );
    Typist::Registry->register_typeclass('Functor', $def);

    my $inst = Typist::TypeClass->new_instance(
        class     => 'Functor',
        type_expr => 'ArrayRef',
        methods   => +{
            fmap => sub ($f, $arr) { [map { $f->($_) } @$arr] },
        },
    );
    Typist::Registry->register_instance('Functor', 'ArrayRef', $inst);

    # Resolve for ArrayRef[Int]
    my $arr_int = Typist::Parser->parse('ArrayRef[Int]');
    my $resolved = Typist::Registry->resolve_instance('Functor', $arr_int);
    ok $resolved, 'resolved Functor instance for ArrayRef[Int]';
    is $resolved->type_expr, 'ArrayRef', 'resolved to ArrayRef instance';

    # Test fmap implementation
    my $fmap = $resolved->get_method('fmap');
    my $doubled = $fmap->(sub ($x) { $x * 2 }, [1, 2, 3]);
    is_deeply $doubled, [2, 4, 6], 'fmap doubles array';
};

subtest 'multiple HKT instances' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Functor',
        var     => 'F: * -> *',
        methods => +{ fmap => 'CodeRef[CodeRef[A -> B], F[A] -> F[B]]' },
    );
    Typist::Registry->register_typeclass('Functor', $def);

    # ArrayRef instance
    my $arr_inst = Typist::TypeClass->new_instance(
        class     => 'Functor',
        type_expr => 'ArrayRef',
        methods   => +{
            fmap => sub ($f, $arr) { [map { $f->($_) } @$arr] },
        },
    );
    Typist::Registry->register_instance('Functor', 'ArrayRef', $arr_inst);

    # HashRef instance (maps over values)
    my $hash_inst = Typist::TypeClass->new_instance(
        class     => 'Functor',
        type_expr => 'HashRef',
        methods   => +{
            fmap => sub ($f, $hash) { +{ map { $_ => $f->($hash->{$_}) } keys %$hash } },
        },
    );
    Typist::Registry->register_instance('Functor', 'HashRef', $hash_inst);

    # Resolve for ArrayRef
    my $arr = Typist::Parser->parse('ArrayRef[Str]');
    my $r1 = Typist::Registry->resolve_instance('Functor', $arr);
    ok $r1 && $r1->type_expr eq 'ArrayRef', 'ArrayRef instance resolved';

    # Resolve for HashRef
    my $hash = Typist::Parser->parse('HashRef[Str, Int]');
    my $r2 = Typist::Registry->resolve_instance('Functor', $hash);
    ok $r2 && $r2->type_expr eq 'HashRef', 'HashRef instance resolved';

    # Test HashRef fmap
    my $fmap = $r2->get_method('fmap');
    my $result = $fmap->(sub ($x) { $x + 10 }, +{ a => 1, b => 2 });
    is $result->{a}, 11, 'HashRef fmap: a -> 11';
    is $result->{b}, 12, 'HashRef fmap: b -> 12';
};

done_testing;
