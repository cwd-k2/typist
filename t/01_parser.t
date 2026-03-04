use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;

# ── Primitive atoms ───────────────────────────────

subtest 'primitive atoms' => sub {
    for my $name (qw(Int Str Double Num Bool Any Void Never Undef)) {
        my $t = Typist::Parser->parse($name);
        ok $t->is_atom, "$name is atom";
        is $t->to_string, $name, "$name to_string";
    }
};

# ── Type variables ────────────────────────────────

subtest 'type variables' => sub {
    for my $v (qw(T U V)) {
        my $t = Typist::Parser->parse($v);
        ok $t->is_var, "$v is var";
        is $t->name, $v, "$v name";
    }
};

# ── Parameterized types ──────────────────────────

subtest 'parameterized types' => sub {
    my $t = Typist::Parser->parse('ArrayRef[Int]');
    ok $t->is_param, 'ArrayRef[Int] is param';
    is $t->base, 'ArrayRef', 'base is ArrayRef';
    is +($t->params)[0]->to_string, 'Int', 'param is Int';

    my $h = Typist::Parser->parse('HashRef[Str, Int]');
    ok $h->is_param, 'HashRef[Str, Int] is param';
    is scalar($h->params), 2, 'two params';
};

# ── Nested parameterized ─────────────────────────

subtest 'nested params' => sub {
    my $t = Typist::Parser->parse('ArrayRef[HashRef[Str]]');
    ok $t->is_param, 'outer is param';
    my ($inner) = $t->params;
    ok $inner->is_param, 'inner is param';
    is $inner->base, 'HashRef', 'inner base is HashRef';
};

# ── Union types ───────────────────────────────────

subtest 'union types' => sub {
    my $t = Typist::Parser->parse('Int | Str');
    ok $t->is_union, 'Int | Str is union';
    is scalar($t->members), 2, 'two members';

    my $t3 = Typist::Parser->parse('Int | Str | Bool');
    ok $t3->is_union, 'three-way union';
    is scalar($t3->members), 3, 'three members';
};

# ── Intersection types ───────────────────────────

subtest 'intersection types' => sub {
    my $t = Typist::Parser->parse('Int & Num');
    ok $t->is_intersection, 'Int & Num is intersection';
    is scalar($t->members), 2, 'two members';
};

# ── Maybe desugaring ─────────────────────────────

subtest 'Maybe desugars to union' => sub {
    my $t = Typist::Parser->parse('Maybe[Str]');
    ok $t->is_union, 'Maybe[Str] is union';
    my @m = $t->members;
    ok((grep { $_->is_atom && $_->name eq 'Str' } @m),   'contains Str');
    ok((grep { $_->is_atom && $_->name eq 'Undef' } @m), 'contains Undef');
};

# ── Function types ────────────────────────────────

subtest 'function types' => sub {
    my $t = Typist::Parser->parse('CodeRef[Str, Int -> Bool]');
    ok $t->is_func, 'CodeRef[...->...] is func';
    is scalar($t->params), 2, 'two params';
    is $t->returns->to_string, 'Bool', 'returns Bool';
};

# ── Struct types ──────────────────────────────────

subtest 'struct types' => sub {
    my $t = Typist::Parser->parse('{ name => Str, age => Int }');
    ok $t->is_record, 'struct is struct';
    my %f = $t->fields;
    is $f{name}->to_string, 'Str', 'name field is Str';
    is $f{age}->to_string,  'Int', 'age field is Int';
};

# ── Optional struct fields ───────────────────────

subtest 'optional struct fields' => sub {
    my $t = Typist::Parser->parse('{ name => Str, age? => Int }');
    ok $t->is_record, 'optional struct is struct';
    my %req = $t->required_fields;
    my %opt = $t->optional_fields;
    is $req{name}->to_string, 'Str', 'name is required Str';
    ok !exists $req{age}, 'age is not required';
    is $opt{age}->to_string, 'Int', 'age is optional Int';

    my $t2 = Typist::Parser->parse('{ x? => Num, y? => Num }');
    my %r2 = $t2->required_fields;
    my %o2 = $t2->optional_fields;
    is scalar keys %r2, 0, 'no required fields';
    is scalar keys %o2, 2, 'two optional fields';
};

# ── Grouping with parens ─────────────────────────

subtest 'parenthesized grouping' => sub {
    my $t = Typist::Parser->parse('(Int | Str)');
    ok $t->is_union, 'parenthesized union';
};

# ── Alias names ───────────────────────────────────

subtest 'alias names' => sub {
    my $t = Typist::Parser->parse('UserId');
    ok $t->is_alias, 'UserId is alias';
    is $t->alias_name, 'UserId', 'alias_name is UserId';
};

# ── Complex nested expression ─────────────────────

subtest 'complex expression' => sub {
    my $t = Typist::Parser->parse('ArrayRef[Int | Str] | Undef');
    ok $t->is_union, 'outer is union';
};

# ── DSL constructor syntax ───────────────────────

subtest 'DSL: Record(...)' => sub {
    my $t = Typist::Parser->parse('Record(name => Str, age => Int)');
    ok $t->is_record, 'Record(...) is struct';
    my %f = $t->fields;
    is $f{name}->to_string, 'Str', 'name field is Str';
    is $f{age}->to_string,  'Int', 'age field is Int';
};

subtest 'DSL: Struct with optional fields' => sub {
    my $t = Typist::Parser->parse('Record(name => Str, age? => Int)');
    ok $t->is_record, 'Struct with optional is struct';
    my %req = $t->required_fields;
    my %opt = $t->optional_fields;
    ok exists $req{name}, 'name is required';
    ok exists $opt{age},  'age is optional';
};

subtest 'DSL: ArrayRef(T)' => sub {
    my $t = Typist::Parser->parse('ArrayRef(Int)');
    ok $t->is_param, 'ArrayRef(...) is param';
    is $t->base, 'ArrayRef', 'base is ArrayRef';
    is +($t->params)[0]->to_string, 'Int', 'param is Int';
};

subtest 'DSL: HashRef(K, V)' => sub {
    my $t = Typist::Parser->parse('HashRef(Str, Int)');
    ok $t->is_param, 'HashRef(...) is param';
    is scalar($t->params), 2, 'two params';
};

subtest 'DSL: Maybe(T)' => sub {
    my $t = Typist::Parser->parse('Maybe(Str)');
    ok $t->is_union, 'Maybe(...) desugars to union';
    my @m = $t->members;
    ok((grep { $_->is_atom && $_->name eq 'Str' } @m),   'contains Str');
    ok((grep { $_->is_atom && $_->name eq 'Undef' } @m), 'contains Undef');
};

subtest 'DSL: Func(A, B, returns => R)' => sub {
    my $t = Typist::Parser->parse('Func(Str, Int, returns => Bool)');
    ok $t->is_func, 'Func(...) is func';
    is scalar($t->params), 2, 'two params';
    is $t->returns->to_string, 'Bool', 'returns Bool';
};

subtest 'DSL: Alias(Name)' => sub {
    my $t = Typist::Parser->parse("Alias('UserId')");
    ok $t->is_alias || $t->is_atom, 'Alias resolves to alias or atom';
    # 'UserId' is not a primitive, should be alias
    ok $t->is_alias, 'UserId is alias';
    is $t->alias_name, 'UserId', 'alias_name is UserId';
};

subtest 'DSL: nested DSL constructors' => sub {
    my $t = Typist::Parser->parse('ArrayRef(Record(x => Int, y => Int))');
    ok $t->is_param, 'outer is param';
    my ($inner) = $t->params;
    ok $inner->is_record, 'inner is struct';
};

subtest 'DSL: mixed bracket and paren' => sub {
    # Bracket syntax still works
    my $t1 = Typist::Parser->parse('ArrayRef[Int]');
    my $t2 = Typist::Parser->parse('ArrayRef(Int)');
    is $t1->to_string, $t2->to_string, 'bracket and paren produce same result';
};

# ── Array / Hash aliases ────────────────────────

subtest 'Array[T] is distinct from ArrayRef[T]' => sub {
    my $t1 = Typist::Parser->parse('Array[Int]');
    my $t2 = Typist::Parser->parse('ArrayRef[Int]');
    ok $t1->is_param, 'Array[Int] is param';
    is $t1->base, 'Array', 'Array base is Array (list type)';
    isnt $t1->to_string, $t2->to_string, 'Array[Int] != ArrayRef[Int]';
};

subtest 'Hash[K,V] is distinct from HashRef[K,V]' => sub {
    my $t1 = Typist::Parser->parse('Hash[Str, Int]');
    my $t2 = Typist::Parser->parse('HashRef[Str, Int]');
    ok $t1->is_param, 'Hash[Str, Int] is param';
    is $t1->base, 'Hash', 'Hash base is Hash (list type)';
    isnt $t1->to_string, $t2->to_string, 'Hash[Str, Int] != HashRef[Str, Int]';
};

subtest 'Array/Hash DSL paren syntax' => sub {
    my $t1 = Typist::Parser->parse('Array(Int)');
    is $t1->base, 'Array', 'Array(Int) base is Array';
    is $t1->to_string, 'Array[Int]', 'Array(Int) stringifies to Array[Int]';

    my $t3 = Typist::Parser->parse('Hash(Str, Int)');
    is $t3->base, 'Hash', 'Hash(Str, Int) base is Hash';
    is $t3->to_string, 'Hash[Str, Int]', 'Hash(Str, Int) stringifies to Hash[Str, Int]';
};

# ── Variadic function types ──────────────────────

subtest 'variadic function type' => sub {
    my $t = Typist::Parser->parse('(Int, ...Str) -> Void');
    ok $t->is_func, 'variadic is func';
    ok $t->variadic, 'variadic flag set';
    my @params = $t->params;
    is scalar @params, 2, 'two params (fixed + rest)';
    is $params[0]->to_string, 'Int', 'fixed param';
    is $params[1]->to_string, 'Str', 'rest element type';
    is $t->to_string, '(Int, ...Str) -> Void', 'to_string shows ...';
};

subtest 'variadic only rest' => sub {
    my $t = Typist::Parser->parse('(...Any) -> Void');
    ok $t->variadic, 'variadic with only rest param';
    my @params = $t->params;
    is scalar @params, 1, 'one param (rest)';
    is $t->to_string, '(...Any) -> Void', 'to_string';
};

subtest 'non-variadic has no flag' => sub {
    my $t = Typist::Parser->parse('(Int, Str) -> Bool');
    ok !$t->variadic, 'regular func not variadic';
};

subtest 'variadic annotation' => sub {
    my $ann = Typist::Parser->parse_annotation('(Int, ...Str) -> Int');
    my $type = $ann->{type};
    ok $type->is_func, 'annotation parses func';
    ok $type->variadic, 'annotation preserves variadic';
};

subtest 'variadic generic annotation' => sub {
    my $ann = Typist::Parser->parse_annotation('<T>(T, ...T) -> T');
    my $type = $ann->{type};
    ok $type->variadic, 'generic variadic';
    is scalar(my @p = $type->params), 2, 'two params';
};

# ── Protocol state in effect row ────────────────

subtest '![DB<None -> Authed>] — state transition' => sub {
    my $func = Typist::Parser->parse('(Str) -> Void ![DB<None -> Authed>]');
    ok $func->is_func, 'parsed as func';
    my $row = $func->effects;
    ok $row->is_row, 'effects is row';
    is_deeply [$row->labels], ['DB'], 'single label DB';
    my $st = $row->label_state('DB');
    ok $st, 'DB has state';
    is $st->{from}, 'None', 'from is None';
    is $st->{to}, 'Authed', 'to is Authed';
    like $row->to_string, qr/DB<None -> Authed>/, 'to_string includes state';
};

subtest '![DB<Authed>] — invariant state' => sub {
    my $func = Typist::Parser->parse('(Str) -> Str ![DB<Authed>]');
    my $row = $func->effects;
    my $st = $row->label_state('DB');
    ok $st, 'DB has state';
    is $st->{from}, 'Authed', 'from is Authed';
    is $st->{to}, 'Authed', 'to equals from (invariant)';
    like $row->to_string, qr/DB<Authed>/, 'to_string shows invariant state';
};

subtest '![DB<None -> Authed>, IO] — mixed' => sub {
    my $func = Typist::Parser->parse('() -> Void ![DB<None -> Authed>, IO]');
    my $row = $func->effects;
    is_deeply [sort $row->labels], [qw(DB IO)], 'two labels';
    ok $row->label_state('DB'), 'DB has state';
    is $row->label_state('IO'), undef, 'IO has no state';
};

subtest 'parse_row with state' => sub {
    my $row = Typist::Parser->parse_row('DB<None -> Connected>, IO, r');
    is_deeply [sort $row->labels], [qw(DB IO)], 'labels';
    ok defined $row->row_var, 'has row var';
    my $st = $row->label_state('DB');
    is $st->{from}, 'None', 'from';
    is $st->{to}, 'Connected', 'to';
};

# ── HKT / multi-char type variable parsing ──────

subtest 'HKT: F[T] → Param(Var(F), [Var(T)])' => sub {
    my $t = Typist::Parser->parse('F[T]');
    ok $t->is_param, 'F[T] is param';
    ok $t->has_var_base, 'base is a type variable';
    is $t->base->name, 'F', 'base var name is F';
    my @p = $t->params;
    is scalar @p, 1, 'one param';
    ok $p[0]->is_var, 'param is Var';
    is $p[0]->name, 'T', 'param name is T';
};

subtest 'multi-char name: Functor[T] → Param(Alias(Functor), [Var(T)])' => sub {
    my $t = Typist::Parser->parse('Functor[T]');
    ok $t->is_param, 'Functor[T] is param';
    my $base = $t->base;
    ok ref $base && $base->is_alias, 'base is Alias';
    is $base->alias_name, 'Functor', 'alias name is Functor';
    my @p = $t->params;
    ok $p[0]->is_var, 'param is Var';
};

subtest 'known constructors still work: ArrayRef[Int]' => sub {
    my $t = Typist::Parser->parse('ArrayRef[Int]');
    ok $t->is_param, 'ArrayRef[Int] is param';
    is $t->base, 'ArrayRef', 'base is string "ArrayRef"';
};

subtest 'Maybe desugar preserved: Maybe[Int]' => sub {
    my $t = Typist::Parser->parse('Maybe[Int]');
    ok $t->is_union, 'Maybe[Int] desugars to union';
};

# ── Compound bounds with + ────────────────────────

subtest 'forall T: A + B compound bound' => sub {
    my $t = Typist::Parser->parse('forall T: Num + Str. T -> T');
    ok $t->is_quantified, 'parsed as Quantified';
    my @vars = $t->vars;
    is scalar @vars, 1, 'one type variable';
    is $vars[0]{name}, 'T', 'var name is T';
    ok $vars[0]{bound}->is_intersection, 'bound is Intersection';
    my @members = $vars[0]{bound}->members;
    is scalar @members, 2, 'intersection has 2 members';
};

subtest 'tokenizer accepts + in type expressions' => sub {
    my @tokens = Typist::Parser::_tokenize('A + B');
    is_deeply \@tokens, [qw(A + B)], 'tokenized A + B';
};

# ── split_type_list ──────────────────────────────

subtest 'split_type_list basic' => sub {
    is_deeply [Typist::Parser->split_type_list('Int, Str')],
        [qw(Int Str)], 'simple comma split';
    is_deeply [Typist::Parser->split_type_list('  A , B , C  ')],
        [qw(A B C)], 'strips whitespace';
};

subtest 'split_type_list bracket nesting' => sub {
    is_deeply [Typist::Parser->split_type_list('Map[K, V], U')],
        ['Map[K, V]', 'U'], '[] nesting preserved';
    is_deeply [Typist::Parser->split_type_list('(Int, Str) -> Bool')],
        ['(Int, Str) -> Bool'], '() nesting preserved';
    is_deeply [Typist::Parser->split_type_list('T: Num, U: Show + Ord')],
        ['T: Num', 'U: Show + Ord'], 'constraint decls';
};

subtest 'split_type_list deep nesting' => sub {
    is_deeply [Typist::Parser->split_type_list('Map[K, Pair[A, B]], V')],
        ['Map[K, Pair[A, B]]', 'V'], 'nested [] preserved';
    is_deeply [Typist::Parser->split_type_list('F: * -> *, T')],
        ['F: * -> *', 'T'], '-> in kind annotation';
};

# ── parse_parameterized_name ────────────────────

subtest 'parse_parameterized_name' => sub {
    is_deeply [Typist::Parser->parse_parameterized_name('Point')],
        ['Point'], 'plain name';
    is_deeply [Typist::Parser->parse_parameterized_name('Option[T]')],
        ['Option', 'T'], 'single param';
    is_deeply [Typist::Parser->parse_parameterized_name('Pair[T: Num, U]')],
        ['Pair', 'T: Num', 'U'], 'constrained params';
    is_deeply [Typist::Parser->parse_parameterized_name('Map[K, Pair[A, B]]')],
        ['Map', 'K', 'Pair[A, B]'], 'nested brackets';
};

# ── parse_param_decls ────────────────────────────

subtest 'parse_param_decls plain names' => sub {
    my @decls = Typist::Parser->parse_param_decls('T, U');
    is scalar @decls, 2, 'two declarations';
    is $decls[0]{name}, 'T', 'first name';
    is $decls[1]{name}, 'U', 'second name';
    ok !exists $decls[0]{constraint_expr}, 'no constraint on T';
};

subtest 'parse_param_decls with constraint' => sub {
    my @decls = Typist::Parser->parse_param_decls('T: Num');
    is scalar @decls, 1, 'one declaration';
    is $decls[0]{name}, 'T', 'name is T';
    is $decls[0]{constraint_expr}, 'Num', 'constraint_expr is Num';
};

subtest 'parse_param_decls compound constraint' => sub {
    my @decls = Typist::Parser->parse_param_decls('T: Show + Ord');
    is $decls[0]{name}, 'T', 'name is T';
    is $decls[0]{constraint_expr}, 'Show + Ord', 'compound constraint preserved';
};

subtest 'parse_param_decls Row variable' => sub {
    my @decls = Typist::Parser->parse_param_decls('r: Row');
    is $decls[0]{name}, 'r', 'name is r';
    ok $decls[0]{is_row_var}, 'is_row_var set';
    is $decls[0]{var_kind}->to_string, 'Row', 'var_kind is Row';
};

subtest 'parse_param_decls HKT kind' => sub {
    my @decls = Typist::Parser->parse_param_decls('F: * -> *');
    is $decls[0]{name}, 'F', 'name is F';
    is $decls[0]{var_kind}->to_string, '* -> *', 'var_kind parsed';
    ok !exists $decls[0]{constraint_expr}, 'no constraint_expr for kind';
};

subtest 'parse_param_decls mixed' => sub {
    my @decls = Typist::Parser->parse_param_decls('T: Num, U: Show + Ord, r: Row, F: * -> *');
    is scalar @decls, 4, 'four declarations';
    is $decls[0]{constraint_expr}, 'Num', 'T: Num';
    is $decls[1]{constraint_expr}, 'Show + Ord', 'U: Show + Ord';
    ok $decls[2]{is_row_var}, 'r: Row';
    is $decls[3]{var_kind}->to_string, '* -> *', 'F: * -> *';
};

subtest 'parse_param_decls single plain name' => sub {
    my @decls = Typist::Parser->parse_param_decls('T');
    is scalar @decls, 1, 'one declaration';
    is $decls[0]{name}, 'T', 'name is T';
};

done_testing;
