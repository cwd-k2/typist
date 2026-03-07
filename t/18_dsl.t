use v5.40;
use Test::More;
use lib 'lib';

use Typist::DSL qw(:all);
use Typist::Type;
use Typist::Subtype;
use Typist::Type::Atom;

# ── Atom Constants ──────────────────────────────

subtest 'Atom constants return correct types' => sub {
    isa_ok Int,   'Typist::Type::Atom';
    isa_ok Str,   'Typist::Type::Atom';
    isa_ok Num,   'Typist::Type::Atom';
    isa_ok Bool,  'Typist::Type::Atom';
    isa_ok Any,   'Typist::Type::Atom';
    isa_ok Void,  'Typist::Type::Atom';
    isa_ok Never, 'Typist::Type::Atom';
    isa_ok Undef, 'Typist::Type::Atom';

    is Int->name,   'Int',   'Int name';
    is Str->name,   'Str',   'Str name';
    is Num->name,   'Num',   'Num name';
    is Bool->name,  'Bool',  'Bool name';
    is Any->name,   'Any',   'Any name';
    is Void->name,  'Void',  'Void name';
    is Never->name, 'Never', 'Never name';
    is Undef->name, 'Undef', 'Undef name';
};

# ── Type Variable Constants ─────────────────────

subtest 'Type variable constants' => sub {
    isa_ok T, 'Typist::Type::Var';
    isa_ok U, 'Typist::Type::Var';
    isa_ok V, 'Typist::Type::Var';
    isa_ok A, 'Typist::Type::Var';
    isa_ok B, 'Typist::Type::Var';
    isa_ok K, 'Typist::Type::Var';

    is T->name, 'T', 'T name';
    is U->name, 'U', 'U name';
};

# ── Parametric Types ────────────────────────────

subtest 'ArrayRef constructor' => sub {
    my $t = ArrayRef(Int);
    isa_ok $t, 'Typist::Type::Param';
    is $t->base, 'ArrayRef', 'base is ArrayRef';
    my @p = $t->params;
    is scalar @p, 1, 'one param';
    ok $p[0]->equals(Int), 'param is Int';
};

subtest 'HashRef constructor' => sub {
    my $t = HashRef(Str);
    isa_ok $t, 'Typist::Type::Param';
    is $t->base, 'HashRef', 'base is HashRef';
};

subtest 'Maybe constructor' => sub {
    my $t = Maybe(Str);
    isa_ok $t, 'Typist::Type::Param';
    is $t->base, 'Maybe', 'base is Maybe';
};

subtest 'Tuple constructor' => sub {
    my $t = Tuple(Int, Str, Bool);
    isa_ok $t, 'Typist::Type::Param';
    is $t->base, 'Tuple', 'base is Tuple';
    is scalar($t->params), 3, 'three params';
};

subtest 'Ref constructor' => sub {
    my $t = Ref(Int);
    isa_ok $t, 'Typist::Type::Param';
    is $t->base, 'Ref', 'base is Ref';
};

# ── Struct ──────────────────────────────────────

subtest 'Struct constructor' => sub {
    my $t = Record(name => Str, age => Int);
    isa_ok $t, 'Typist::Type::Record';
    ok $t->is_record, 'is_record';
    my %r = $t->required_fields;
    ok exists $r{name}, 'has name field';
    ok exists $r{age},  'has age field';
};

subtest 'Struct with optional fields' => sub {
    my $t = Record(name => Str, 'email?' => Str);
    my %r = $t->required_fields;
    my %o = $t->optional_fields;
    ok exists $r{name},  'name is required';
    ok exists $o{email}, 'email is optional';
};

# ── Func ────────────────────────────────────────

subtest 'Func constructor' => sub {
    my $t = Func(Int, Str, returns => Bool);
    isa_ok $t, 'Typist::Type::Func';
    ok $t->is_func, 'is_func';
    my @p = $t->params;
    is scalar @p, 2, 'two params';
    ok $t->returns->equals(Bool), 'returns Bool';
};

# ── Literal ─────────────────────────────────────

subtest 'Literal constructor' => sub {
    my $lit_int = Literal(42);
    isa_ok $lit_int, 'Typist::Type::Literal';
    is $lit_int->value, 42, 'value is 42';
    is $lit_int->base_type, 'Int', 'base_type is Int';

    my $lit_str = Literal("hello");
    is $lit_str->base_type, 'Str', 'string literal base_type is Str';
};

# ── TVar ────────────────────────────────────────

subtest 'TVar constructor' => sub {
    my $t = TVar('Elem');
    isa_ok $t, 'Typist::Type::Var';
    is $t->name, 'Elem', 'custom var name';
};

# ── Alias ───────────────────────────────────────

subtest 'Alias constructor' => sub {
    my $t = Alias('UserId');
    isa_ok $t, 'Typist::Type::Alias';
    is $t->alias_name, 'UserId', 'alias name';
};

# ── Row / Eff ───────────────────────────────────

subtest 'Row constructor' => sub {
    my $r = Row(labels => ['Console', 'State']);
    isa_ok $r, 'Typist::Type::Row';
    ok $r->is_row, 'is_row';
    my @labels = $r->labels;
    is scalar @labels, 2, 'two labels';
};

subtest 'Eff constructor' => sub {
    my $r = Row(labels => ['Console']);
    my $e = Eff($r);
    isa_ok $e, 'Typist::Type::Eff';
    ok $e->is_eff, 'is_eff';
};

# ── Operator Overloads ──────────────────────────

subtest 'Union via | operator' => sub {
    my $t = Int | Str;
    isa_ok $t, 'Typist::Type::Union';
    ok $t->is_union, 'is_union';
    my @m = $t->members;
    is scalar @m, 2, 'two members';
};

subtest 'Intersection via & operator' => sub {
    my $t = Int & Num;
    isa_ok $t, 'Typist::Type::Intersection';
    ok $t->is_intersection, 'is_intersection';
};

subtest 'Stringification via ""' => sub {
    is "${\Int}", 'Int', 'Int stringifies';
    like "${\ArrayRef(Str)}", qr/ArrayRef\[Str\]/, 'ArrayRef[Str] stringifies';
};

# ── Type->coerce ────────────────────────────────

subtest 'Type->coerce passes through objects' => sub {
    my $t = Int;
    my $c = Typist::Type->coerce($t);
    ok $c->equals($t), 'coerce passthrough';
};

subtest 'Type->coerce parses strings' => sub {
    my $t = Typist::Type->coerce('Int | Str');
    ok $t->is_union, 'parsed to union';
};

# ── Composability ───────────────────────────────

subtest 'Nested DSL composition' => sub {
    my $t = ArrayRef(Int | Str);
    ok $t->is_param, 'is param';
    my @p = $t->params;
    ok $p[0]->is_union, 'inner is union';
};

subtest 'Func with DSL types' => sub {
    my $t = Func(ArrayRef(T), returns => T);
    ok $t->is_func, 'is func';
    my @p = $t->params;
    ok $p[0]->is_param, 'param is ArrayRef';
    ok $t->returns->is_var, 'returns is var T';
};

# ── optional() ─────────────────────────────────

subtest 'optional returns key? pair' => sub {
    my @pair = optional(email => Str);
    is $pair[0], 'email?', 'key gets ? suffix';
    ok $pair[1]->equals(Str), 'value is the type';
};

subtest 'optional in Record constructor' => sub {
    my $t = Record(name => Str, optional(email => Str), age => Int);
    my %r = $t->required_fields;
    my %o = $t->optional_fields;
    ok exists $r{name}, 'name is required';
    ok exists $r{age},  'age is required';
    ok exists $o{email}, 'email is optional via optional()';
    ok $o{email}->equals(Str), 'email type is Str';
    ok !exists $r{email}, 'email not in required';
};

subtest 'optional with string type' => sub {
    my @pair = optional(age => 'Int');
    is $pair[0], 'age?', 'key gets ? suffix';
    is $pair[1], 'Int',  'string type preserved';
};

# ── Array / Hash list types ───────────────────────

subtest 'Array constructor (list type, distinct from ArrayRef)' => sub {
    my $t = Array(Int);
    ok $t->is_param, 'Array(Int) is param';
    is $t->base, 'Array', 'Array base is Array';
    is $t->to_string, 'Array[Int]', 'Array(Int) stringifies correctly';
};

subtest 'Hash constructor (list type, distinct from HashRef)' => sub {
    my $t = Hash(Str, Int);
    ok $t->is_param, 'Hash(Str, Int) is param';
    is $t->base, 'Hash', 'Hash base is Hash';
    is $t->to_string, 'Hash[Str, Int]', 'Hash(Str, Int) stringifies correctly';
};

done_testing;
