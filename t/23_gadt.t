use v5.40;
use Test::More;
use lib 'lib';
use Typist -runtime;

# ── GADT basic construction ─────────────────────

subtest 'GADT: basic construction with forced type_args' => sub {
    Typist::Registry->reset;

    datatype 'Expr[A]' =>
        IntLit  => '(Int) -> Expr[Int]',
        BoolLit => '(Bool) -> Expr[Bool]',
        Add     => '(Expr[Int], Expr[Int]) -> Expr[Int]';

    my $e = IntLit(42);
    is $e->{_tag}, 'IntLit', 'IntLit tag';
    is_deeply $e->{_values}, [42], 'IntLit values';
    ok $e->{_type_args}[0]->is_atom && $e->{_type_args}[0]->name eq 'Int',
        'IntLit forces type_arg to Int';

    my $b = BoolLit(1);
    ok $b->{_type_args}[0]->is_atom && $b->{_type_args}[0]->name eq 'Bool',
        'BoolLit forces type_arg to Bool';

    my $sum = Add(IntLit(1), IntLit(2));
    ok $sum->{_type_args}[0]->is_atom && $sum->{_type_args}[0]->name eq 'Int',
        'Add forces type_arg to Int';
};

# ── GADT with free type variable ────────────────

subtest 'GADT: constructor with free type variable' => sub {
    Typist::Registry->reset;

    datatype 'Val[A]' =>
        IntVal  => '(Int) -> Val[Int]',
        StrVal  => '(Str) -> Val[Str]',
        AnyVal  => '(A)';  # implicit -> Val[A], inferred

    my $iv = IntVal(10);
    ok $iv->{_type_args}[0]->is_atom && $iv->{_type_args}[0]->name eq 'Int',
        'IntVal: forced A=Int';

    # AnyVal(42) should infer A=Int
    my $av = AnyVal(42);
    ok $av->{_type_args}[0]->is_atom && $av->{_type_args}[0]->name eq 'Int',
        'AnyVal(42): inferred A=Int';
};

# ── GADT: is_gadt predicate via Registry ─────────

subtest 'GADT: is_gadt via Registry' => sub {
    Typist::Registry->reset;

    datatype Shape => Circle => '(Int)', Rect => '(Int, Int)';
    my $shape_dt = Typist::Registry->lookup_datatype('Shape');
    ok !$shape_dt->is_gadt, 'Shape is not GADT';

    datatype 'Expr[A]' =>
        IntLit => '(Int) -> Expr[Int]';
    my $expr_dt = Typist::Registry->lookup_datatype('Expr');
    ok $expr_dt->is_gadt, 'Expr is GADT';
};

# ── GADT: match still works ─────────────────────

subtest 'GADT: match dispatches normally' => sub {
    Typist::Registry->reset;

    datatype 'Expr[A]' =>
        IntLit  => '(Int) -> Expr[Int]',
        BoolLit => '(Bool) -> Expr[Bool]';

    my $e = IntLit(42);
    my $result = match $e,
        IntLit  => sub ($n) { $n + 1 },
        BoolLit => sub ($b) { !$b };
    is $result, 43, 'match on GADT dispatches correctly';
};

# ── GADT: return_types stored in Data ────────────

subtest 'GADT: return_types stored in Data type' => sub {
    Typist::Registry->reset;

    datatype 'Expr[A]' =>
        IntLit  => '(Int) -> Expr[Int]',
        BoolLit => '(Bool) -> Expr[Bool]',
        If      => '(Expr[Bool], Expr[A], Expr[A]) -> Expr[A]';

    my $dt = Typist::Registry->lookup_datatype('Expr');
    ok $dt->is_gadt, 'is_gadt';

    my $rt = $dt->return_types;
    ok exists $rt->{IntLit},  'IntLit has return_type';
    ok exists $rt->{BoolLit}, 'BoolLit has return_type';
    ok exists $rt->{If},      'If has return_type';

    # IntLit return_type should be Expr[Int]
    is $rt->{IntLit}->to_string, 'Expr[Int]', 'IntLit -> Expr[Int]';
    is $rt->{BoolLit}->to_string, 'Expr[Bool]', 'BoolLit -> Expr[Bool]';
    is $rt->{If}->to_string, 'Expr[A]', 'If -> Expr[A]';
};

# ── GADT: backward compat with normal ADT ───────

subtest 'GADT: normal ADT still works' => sub {
    Typist::Registry->reset;

    datatype 'Option[T]' =>
        Some => '(T)',
        None => '()';

    my $s = Some(42);
    is $s->{_tag}, 'Some', 'Some tag';
    ok $s->{_type_args}[0]->is_atom && $s->{_type_args}[0]->name eq 'Int',
        'Some(42) infers T=Int';

    my $n = None();
    is $n->{_tag}, 'None', 'None tag';

    my $dt = Typist::Registry->lookup_datatype('Option');
    ok !$dt->is_gadt, 'Option is not GADT';
};

done_testing;
