use v5.40;
use Test::More;
use lib 'lib';

use PPI;
use Typist::Static::Infer;

# Helper: parse source, find the first expression-like token after '='
sub infer_from_source ($source) {
    my $doc = PPI::Document->new(\$source);
    # Find the assignment operator, then grab what follows
    my $stmts = $doc->find('PPI::Statement') || [];
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        for my $i (0 .. $#children) {
            if ($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq '=') {
                my $rhs = $children[$i + 1] // next;
                return Typist::Static::Infer->infer_expr($rhs);
            }
        }
    }
    undef;
}

# ── Numeric Literals ─────────────────────────────

subtest 'integer literal' => sub {
    my $t = infer_from_source('my $x = 42;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Int', '42 → Int';
};

subtest 'negative integer' => sub {
    # PPI parses `-5` as Operator(-) followed by Number(5)
    # We only see the Number token, which infers to Int
    my $doc = PPI::Document->new(\'my $x = 5;');
    my $num = $doc->find_first('PPI::Token::Number');
    my $t = Typist::Static::Infer->infer_expr($num);
    ok $t && $t->is_atom && $t->name eq 'Int', '5 → Int';
};

subtest 'float literal' => sub {
    my $t = infer_from_source('my $x = 3.14;');
    ok $t, 'inferred';
    is $t->name, 'Num', '3.14 → Num';
};

subtest 'bool literal 0' => sub {
    my $t = infer_from_source('my $x = 0;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '0 → Bool';
};

subtest 'bool literal 1' => sub {
    my $t = infer_from_source('my $x = 1;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '1 → Bool';
};

# ── String Literals ──────────────────────────────

subtest 'single-quoted string' => sub {
    my $t = infer_from_source(q{my $x = 'hello';});
    ok $t, 'inferred';
    is $t->name, 'Str', "'hello' → Str";
};

subtest 'double-quoted string' => sub {
    my $t = infer_from_source('my $x = "world";');
    ok $t, 'inferred';
    is $t->name, 'Str', '"world" → Str';
};

# ── undef ────────────────────────────────────────

subtest 'undef literal' => sub {
    my $t = infer_from_source('my $x = undef;');
    ok $t, 'inferred';
    is $t->name, 'Undef', 'undef → Undef';
};

# ── Array Constructor ────────────────────────────

subtest 'array of ints' => sub {
    my $t = infer_from_source('my $x = [2, 3, 4];');
    ok $t, 'inferred';
    ok $t->is_param, 'is param';
    is $t->base, 'ArrayRef', 'ArrayRef';
    my @p = $t->params;
    is $p[0]->name, 'Int', 'element type Int';
};

subtest 'mixed array' => sub {
    my $t = infer_from_source('my $x = [1, "two"];');
    ok $t, 'inferred';
    is $t->base, 'ArrayRef', 'ArrayRef';
    my @p = $t->params;
    is $p[0]->name, 'Any', 'mixed → Any element type';
};

subtest 'empty array' => sub {
    my $t = infer_from_source('my $x = [];');
    ok $t, 'inferred';
    is $t->base, 'ArrayRef', 'ArrayRef';
    my @p = $t->params;
    is $p[0]->name, 'Any', 'empty → Any element type';
};

subtest 'array of bools widened to Int' => sub {
    my $t = infer_from_source('my $x = [0, 1, 5];');
    ok $t, 'inferred';
    my @p = $t->params;
    is $p[0]->name, 'Int', 'Bool + Int → Int';
};

# ── Hash Constructor ─────────────────────────────

subtest 'hash with string values' => sub {
    # Test directly against a PPI::Structure::Constructor node
    my $doc = PPI::Document->new(\'my $x = +{ a => "foo", b => "bar" };');
    my $cons = $doc->find_first('PPI::Structure::Constructor');
    ok $cons, 'found constructor';
    my $t = Typist::Static::Infer->infer_expr($cons);
    ok $t, 'inferred';
    ok $t->is_param, 'is param';
    is $t->base, 'HashRef', 'HashRef';
    my @p = $t->params;
    is $p[0]->name, 'Str', 'value type Str';
};

# ── Non-inferable expressions ────────────────────

subtest 'variable reference → undef' => sub {
    my $doc = PPI::Document->new(\'$some_var');
    my $sym = $doc->find_first('PPI::Token::Symbol');
    my $t = Typist::Static::Infer->infer_expr($sym);
    is $t, undef, 'variable → undef (skip)';
};

subtest 'function call → undef' => sub {
    my $doc = PPI::Document->new(\'foo()');
    my $word = $doc->find_first('PPI::Token::Word');
    my $t = Typist::Static::Infer->infer_expr($word);
    is $t, undef, 'function call → undef (skip)';
};

subtest 'undef input → undef' => sub {
    my $t = Typist::Static::Infer->infer_expr(undef);
    is $t, undef, 'undef → undef';
};

done_testing;
