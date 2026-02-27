use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;

# ── Primitive atoms ───────────────────────────────

subtest 'primitive atoms' => sub {
    for my $name (qw(Int Str Num Bool Any Void Never Undef)) {
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
    ok $t->is_struct, 'struct is struct';
    my %f = $t->fields;
    is $f{name}->to_string, 'Str', 'name field is Str';
    is $f{age}->to_string,  'Int', 'age field is Int';
};

# ── Optional struct fields ───────────────────────

subtest 'optional struct fields' => sub {
    my $t = Typist::Parser->parse('{ name => Str, age? => Int }');
    ok $t->is_struct, 'optional struct is struct';
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

subtest 'DSL: Struct(...)' => sub {
    my $t = Typist::Parser->parse('Struct(name => Str, age => Int)');
    ok $t->is_struct, 'Struct(...) is struct';
    my %f = $t->fields;
    is $f{name}->to_string, 'Str', 'name field is Str';
    is $f{age}->to_string,  'Int', 'age field is Int';
};

subtest 'DSL: Struct with optional fields' => sub {
    my $t = Typist::Parser->parse('Struct(name => Str, age? => Int)');
    ok $t->is_struct, 'Struct with optional is struct';
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
    my $t = Typist::Parser->parse('ArrayRef(Struct(x => Int, y => Int))');
    ok $t->is_param, 'outer is param';
    my ($inner) = $t->params;
    ok $inner->is_struct, 'inner is struct';
};

subtest 'DSL: mixed bracket and paren' => sub {
    # Bracket syntax still works
    my $t1 = Typist::Parser->parse('ArrayRef[Int]');
    my $t2 = Typist::Parser->parse('ArrayRef(Int)');
    is $t1->to_string, $t2->to_string, 'bracket and paren produce same result';
};

done_testing;
