use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;

sub parse { Typist::Parser->parse(@_) }

# ── Empty / whitespace input ────────────────────

subtest 'empty input dies' => sub {
    eval { parse('') };
    ok $@, 'empty string dies';

    eval { parse('   ') };
    ok $@, 'whitespace-only dies';
};

# ── Malformed syntax ────────────────────────────

subtest 'unclosed bracket dies' => sub {
    eval { parse('ArrayRef[Int') };
    ok $@, 'unclosed [ dies';
    like $@, qr/bracket|unexpected|parse/i, 'meaningful error message';
};

subtest 'mismatched brackets die' => sub {
    eval { parse('ArrayRef[Int)') };
    ok $@, 'mismatched brackets die';
};

subtest 'unclosed paren dies' => sub {
    eval { parse('(Int, Str') };
    ok $@, 'unclosed ( dies';
};

# ── Deep nesting ────────────────────────────────

subtest 'deep nesting (depth 4+)' => sub {
    my $t = parse('ArrayRef[ArrayRef[ArrayRef[ArrayRef[Int]]]]');
    ok $t->is_param, 'depth-4 nesting parses';
    my ($l1) = $t->params;
    ok $l1->is_param, 'level 1 is param';
    my ($l2) = $l1->params;
    ok $l2->is_param, 'level 2 is param';
    my ($l3) = $l2->params;
    ok $l3->is_param, 'level 3 is param';
    is(($l3->params)[0]->to_string, 'Int', 'innermost is Int');
};

subtest 'deep nested union in param' => sub {
    my $t = parse('ArrayRef[Int | Str | Bool]');
    ok $t->is_param, 'ArrayRef[Union] parses';
    my ($inner) = $t->params;
    ok $inner->is_union, 'inner is union';
    is scalar($inner->members), 3, 'three union members';
};

# ── Empty record ────────────────────────────────

subtest 'empty record {}' => sub {
    my $t = parse('{}');
    ok $t->is_record, 'empty record parses';
    is scalar(keys %{{ $t->required_fields }}), 0, 'no required fields';
    is scalar(keys %{{ $t->optional_fields }}), 0, 'no optional fields';
};

# ── Empty-param function ────────────────────────

subtest 'empty-param function () -> T' => sub {
    my $t = parse('() -> Int');
    ok $t->is_func, 'zero-param func parses';
    is scalar($t->params), 0, 'no params';
    is $t->returns->to_string, 'Int', 'returns Int';
};

subtest 'empty-param with effects () -> Void ![IO]' => sub {
    my $t = parse('() -> Void ![IO]');
    ok $t->is_func, 'zero-param effectful func parses';
    is scalar($t->params), 0, 'no params';
    ok $t->effects, 'has effects';
    is_deeply [$t->effects->labels], ['IO'], 'IO effect';
};

# ── Forall edge cases ──────────────────────────

subtest 'forall with bound' => sub {
    my $t = parse('forall T: Num. T -> T');
    ok $t->is_quantified, 'bounded forall parses';
    my @vars = $t->vars;
    ok $vars[0]{bound}, 'T has bound';
    is $vars[0]{bound}->to_string, 'Num', 'bound is Num';
};

subtest 'forall multi-variable' => sub {
    my $t = parse('forall A B. A -> B');
    ok $t->is_quantified, 'multi-var forall parses';
    my @vars = $t->vars;
    is scalar @vars, 2, 'two quantified vars';
    is $vars[0]{name}, 'A', 'first var is A';
    is $vars[1]{name}, 'B', 'second var is B';
};

# ── Variadic edge cases ────────────────────────

subtest 'variadic with complex rest type' => sub {
    my $t = parse('(Int, ...ArrayRef[Str]) -> Void');
    ok $t->is_func, 'variadic with complex rest parses';
    ok $t->variadic, 'variadic flag set';
    my @params = $t->params;
    is $params[1]->to_string, 'ArrayRef[Str]', 'rest type is ArrayRef[Str]';
};

# ── Literal edge cases ─────────────────────────

subtest 'literal integer' => sub {
    my $t = parse('42');
    ok $t->is_literal, '42 is literal';
    is $t->value, 42, 'value is 42';
    is $t->base_type, 'Int', 'base type is Int';
};

subtest 'literal zero' => sub {
    my $t = parse('0');
    ok $t->is_literal, '0 is literal';
    is $t->value, 0, 'value is 0';
    is $t->base_type, 'Int', 'base type is Int';
};

subtest 'literal float' => sub {
    my $t = parse('3.14');
    ok $t->is_literal, '3.14 is literal';
    is $t->base_type, 'Double', 'base type is Double';
};

subtest 'literal string double-quoted' => sub {
    my $t = parse('"hello"');
    ok $t->is_literal, '"hello" is literal';
    is $t->value, 'hello', 'value is hello';
    is $t->base_type, 'Str', 'base type is Str';
};

subtest 'literal string single-quoted' => sub {
    my $t = parse("'world'");
    ok $t->is_literal, "'world' is literal";
    is $t->value, 'world', 'value is world';
    is $t->base_type, 'Str', 'base type is Str';
};

subtest 'literal empty string' => sub {
    my $t = parse('""');
    ok $t->is_literal, '"" is literal';
    is $t->value, '', 'value is empty';
    is $t->base_type, 'Str', 'base type is Str';
};

subtest 'literal negative integer' => sub {
    my $t = parse('-1');
    ok $t->is_literal, '-1 is literal';
    is $t->base_type, 'Int', 'base type is Int';
};

# ── Annotation with deep generics ──────────────

subtest 'annotation with nested generic params' => sub {
    my $ann = Typist::Parser->parse_annotation(
        '<T, U>(ArrayRef[HashRef[Str, T]], U) -> Maybe[T]'
    );
    ok $ann, 'complex annotation parses';
    my $type = $ann->{type};
    ok $type->is_func, 'is func';
    my @gen = @{ $ann->{generics} // [] };
    is scalar @gen, 2, 'two generic params';
    is $gen[0], 'T', 'first generic is T';
    is $gen[1], 'U', 'second generic is U';

    my @params = $type->params;
    is scalar @params, 2, 'two params';
    ok $params[0]->is_param, 'first param is parameterized';
    is $params[0]->base, 'ArrayRef', 'first param base is ArrayRef';
};

subtest 'annotation with effects and generics' => sub {
    my $ann = Typist::Parser->parse_annotation(
        '<T: Num>(T, T) -> T ![Console, IO]'
    );
    ok $ann, 'generic + effects annotation parses';
    my $type = $ann->{type};
    ok $type->effects, 'has effects';
    is_deeply [sort $type->effects->labels], [qw(Console IO)], 'two effect labels';
    like($ann->{generics}->[0], qr/^T/, 'generic starts with T');
};

# ── Complex type expressions ────────────────────

subtest 'function returning function' => sub {
    my $t = parse('(Int) -> (Str) -> Bool');
    ok $t->is_func, 'higher-order func parses';
    ok $t->returns->is_func, 'return type is func';
    is $t->returns->returns->to_string, 'Bool', 'inner return is Bool';
};

subtest 'union of parameterized types' => sub {
    my $t = parse('ArrayRef[Int] | ArrayRef[Str]');
    ok $t->is_union, 'union of params parses';
    my @m = $t->members;
    is scalar @m, 2, 'two members';
    ok $m[0]->is_param, 'first member is param';
    ok $m[1]->is_param, 'second member is param';
};

subtest 'Tuple type' => sub {
    my $t = parse('Tuple[Int, Str, Bool]');
    ok $t->is_param, 'Tuple parses as param';
    is $t->base, 'Tuple', 'base is Tuple';
    is scalar($t->params), 3, 'three type args';
};

done_testing;
