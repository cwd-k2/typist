use v5.40;
use Test::More;
use lib 'lib';
use Typist::Kind;
use Typist::KindChecker;
use Typist::Parser;
use Typist::Registry;
use Typist::TypeClass;
use Typist::Type::Var;
use Typist::Type::Param;
use Typist::Type::Atom;
use Typist::Type::Alias;

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

# ── Type Variable Application (HKT) ─────────────

subtest 'parse F[T] — type variable application' => sub {
    my $type = Typist::Parser->parse('F[T]');
    ok $type->is_param, 'F[T] is Param';
    ok $type->has_var_base, 'F[T] has Var base';
    ok $type->base->is_var, 'base is Var';
    is $type->base->name, 'F', 'base var name is F';

    my @params = $type->params;
    is scalar @params, 1, 'one type parameter';
    ok $params[0]->is_var, 'param is Var';
    is $params[0]->name, 'T', 'param var name is T';

    is $type->to_string, 'F[T]', 'to_string round-trips';
};

subtest 'parse F[Int] — type variable applied to concrete type' => sub {
    my $type = Typist::Parser->parse('F[Int]');
    ok $type->is_param, 'F[Int] is Param';
    ok $type->has_var_base, 'F[Int] has Var base';
    is $type->base->name, 'F', 'base var name is F';

    my @params = $type->params;
    is scalar @params, 1, 'one type parameter';
    ok $params[0]->is_atom, 'param is Atom';
    is $params[0]->name, 'Int', 'param is Int';

    is $type->to_string, 'F[Int]', 'to_string round-trips';
};

subtest 'parse F[A, B] — multi-param type variable application' => sub {
    my $type = Typist::Parser->parse('F[A, B]');
    ok $type->is_param, 'F[A, B] is Param';
    ok $type->has_var_base, 'has Var base';
    is $type->base->name, 'F', 'base is F';

    my @params = $type->params;
    is scalar @params, 2, 'two type parameters';
    ok $params[0]->is_var && $params[0]->name eq 'A', 'first param is A';
    ok $params[1]->is_var && $params[1]->name eq 'B', 'second param is B';

    is $type->to_string, 'F[A, B]', 'to_string round-trips';
};

subtest 'parse distinguishes ArrayRef[T] from F[T]' => sub {
    my $arr = Typist::Parser->parse('ArrayRef[T]');
    ok $arr->is_param, 'ArrayRef[T] is Param';
    ok !$arr->has_var_base, 'ArrayRef[T] has string base (not Var)';
    is $arr->base, 'ArrayRef', 'base is string ArrayRef';

    my $fvar = Typist::Parser->parse('F[T]');
    ok $fvar->is_param, 'F[T] is Param';
    ok $fvar->has_var_base, 'F[T] has Var base';
};

subtest 'parse F[T] in function type annotation' => sub {
    my $result = Typist::Parser->parse_annotation('<F: * -> *, T>(T) -> F[T]');
    is scalar $result->{generics_raw}->@*, 2, 'two generic params';
    is $result->{generics_raw}[0], 'F: * -> *', 'first generic is F: * -> *';
    is $result->{generics_raw}[1], 'T', 'second generic is T';

    my $type = $result->{type};
    ok $type->is_func, 'parsed type is Func';
    my @params = $type->params;
    is scalar @params, 1, 'one param';
    ok $params[0]->is_var, 'param is Var T';

    my $ret = $type->returns;
    ok $ret->is_param, 'return type is Param';
    ok $ret->has_var_base, 'return type has Var base';
    is $ret->base->name, 'F', 'return base is F';
    is $ret->to_string, 'F[T]', 'return type is F[T]';
};

subtest 'kind check: F[Int] valid when F: * -> *' => sub {
    my $star    = Typist::Kind->Star;
    my $f_kind  = Typist::Kind->parse('* -> *');
    my $type    = Typist::Parser->parse('F[Int]');
    my $result  = Typist::KindChecker->infer_kind($type, +{ F => $f_kind });
    ok $result->equals($star), 'F[Int] has kind * when F: * -> *';
};

subtest 'kind check: F[Int] invalid when F: *' => sub {
    my $star = Typist::Kind->Star;
    my $type = Typist::Parser->parse('F[Int]');
    eval { Typist::KindChecker->infer_kind($type, +{ F => $star }) };
    like $@, qr/too many/, 'F[Int] is kind error when F: *';
};

subtest 'kind check: F[Int] with F: * -> * -> * yields * -> *' => sub {
    my $star      = Typist::Kind->Star;
    my $f_kind    = Typist::Kind->parse('* -> * -> *');
    my $type      = Typist::Parser->parse('F[Int]');
    my $result    = Typist::KindChecker->infer_kind($type, +{ F => $f_kind });
    my $expected  = Typist::Kind->parse('* -> *');
    ok $result->equals($expected), 'F[Int] has kind * -> * when F: * -> * -> *';
};

subtest 'substitute: F[T] with F=>ArrayRef, T=>Int yields ArrayRef[Int]' => sub {
    my $type     = Typist::Parser->parse('F[T]');
    my $int_atom = Typist::Type::Atom->new('Int');
    my $arr_alias = Typist::Type::Alias->new('ArrayRef');

    my $result = $type->substitute(+{ F => $arr_alias, T => $int_atom });
    ok $result->is_param, 'result is Param';
    is $result->base, 'ArrayRef', 'base normalized to string ArrayRef';
    ok !$result->has_var_base, 'base is no longer a Var';

    my @params = $result->params;
    is scalar @params, 1, 'one param';
    ok $params[0]->is_atom && $params[0]->name eq 'Int', 'param is Int';

    is $result->to_string, 'ArrayRef[Int]', 'result is ArrayRef[Int]';
};

subtest 'substitute: partial — only T, F remains' => sub {
    my $type     = Typist::Parser->parse('F[T]');
    my $int_atom = Typist::Type::Atom->new('Int');

    my $result = $type->substitute(+{ T => $int_atom });
    ok $result->is_param, 'result is Param';
    ok $result->has_var_base, 'base is still Var F';
    is $result->base->name, 'F', 'base name is F';
    is $result->to_string, 'F[Int]', 'result is F[Int]';
};

subtest 'free_vars includes base var' => sub {
    my $type = Typist::Parser->parse('F[T]');
    my @fv = sort $type->free_vars;
    is_deeply \@fv, ['F', 'T'], 'free vars are F and T';
};

subtest 'equals for type variable application' => sub {
    my $a = Typist::Parser->parse('F[T]');
    my $b = Typist::Parser->parse('F[T]');
    ok $a->equals($b), 'F[T] equals F[T]';

    my $c = Typist::Parser->parse('G[T]');
    ok !$a->equals($c), 'F[T] does not equal G[T]';

    my $d = Typist::Parser->parse('F[U]');
    ok !$a->equals($d), 'F[T] does not equal F[U]';
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
