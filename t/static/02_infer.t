use v5.40;
use Test::More;
use lib 'lib';

use PPI;
use Typist::Static::Infer;
use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Struct;

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
    ok $t->is_literal, 'is literal';
    is $t->base_type, 'Int', '42 → Literal(Int)';
};

subtest 'negative integer' => sub {
    # PPI parses `-5` as Operator(-) followed by Number(5)
    # We only see the Number token, which infers to Literal(Int)
    my $doc = PPI::Document->new(\'my $x = 5;');
    my $num = $doc->find_first('PPI::Token::Number');
    my $t = Typist::Static::Infer->infer_expr($num);
    ok $t && $t->is_literal && $t->base_type eq 'Int', '5 → Literal(Int)';
};

subtest 'float literal' => sub {
    my $t = infer_from_source('my $x = 3.14;');
    ok $t, 'inferred';
    is $t->base_type, 'Num', '3.14 → Literal(Num)';
};

subtest 'bool literal 0' => sub {
    my $t = infer_from_source('my $x = 0;');
    ok $t, 'inferred';
    is $t->base_type, 'Bool', '0 → Literal(Bool)';
};

subtest 'bool literal 1' => sub {
    my $t = infer_from_source('my $x = 1;');
    ok $t, 'inferred';
    is $t->base_type, 'Bool', '1 → Literal(Bool)';
};

# ── String Literals ──────────────────────────────

subtest 'single-quoted string' => sub {
    my $t = infer_from_source(q{my $x = 'hello';});
    ok $t, 'inferred';
    ok $t->is_literal, 'is literal';
    is $t->base_type, 'Str', "'hello' → Literal(Str)";
};

subtest 'double-quoted string' => sub {
    my $t = infer_from_source('my $x = "world";');
    ok $t, 'inferred';
    is $t->base_type, 'Str', '"world" → Literal(Str)';
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
    is scalar @p, 2, 'two params (key, value)';
    is $p[0]->name, 'Str', 'key type Str';
    is $p[1]->name, 'Str', 'value type Str';
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

# ── Operator Expressions ────────────────────────

# Helper: parse a bare expression and infer from the Statement node
sub infer_stmt ($source, $env = undef) {
    my $doc = PPI::Document->new(\$source);
    my $stmt = $doc->find_first('PPI::Statement');
    return undef unless $stmt;
    Typist::Static::Infer->infer_expr($stmt, $env);
}

# ── Arithmetic ──────────────────────────────────

subtest 'addition → Num' => sub {
    my $t = infer_stmt('$a + $b;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Num', '$a + $b → Num';
};

subtest 'subtraction → Num' => sub {
    my $t = infer_stmt('$a - $b;');
    ok $t, 'inferred';
    is $t->name, 'Num', '$a - $b → Num';
};

subtest 'multiplication → Num' => sub {
    my $t = infer_stmt('$a * $b;');
    ok $t, 'inferred';
    is $t->name, 'Num', '$a * $b → Num';
};

subtest 'division → Num' => sub {
    my $t = infer_stmt('$a / $b;');
    ok $t, 'inferred';
    is $t->name, 'Num', '$a / $b → Num';
};

subtest 'modulo → Num' => sub {
    my $t = infer_stmt('$a % $b;');
    ok $t, 'inferred';
    is $t->name, 'Num', '$a % $b → Num';
};

subtest 'exponentiation → Num' => sub {
    my $t = infer_stmt('$a ** $b;');
    ok $t, 'inferred';
    is $t->name, 'Num', '$a ** $b → Num';
};

# ── String Concatenation ────────────────────────

subtest 'concatenation → Str' => sub {
    my $t = infer_stmt('$a . $b;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Str', '$a . $b → Str';
};

# ── Numeric Comparison ──────────────────────────

subtest 'numeric eq → Bool' => sub {
    my $t = infer_stmt('$a == $b;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Bool', '$a == $b → Bool';
};

subtest 'numeric ne → Bool' => sub {
    my $t = infer_stmt('$a != $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a != $b → Bool';
};

subtest 'less than → Bool' => sub {
    my $t = infer_stmt('$a < $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a < $b → Bool';
};

subtest 'greater than → Bool' => sub {
    my $t = infer_stmt('$a > $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a > $b → Bool';
};

subtest 'less or equal → Bool' => sub {
    my $t = infer_stmt('$a <= $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a <= $b → Bool';
};

subtest 'greater or equal → Bool' => sub {
    my $t = infer_stmt('$a >= $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a >= $b → Bool';
};

subtest 'spaceship → Bool' => sub {
    my $t = infer_stmt('$a <=> $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a <=> $b → Bool';
};

# ── String Comparison ───────────────────────────

subtest 'string eq → Bool' => sub {
    my $t = infer_stmt('$a eq $b;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Bool', '$a eq $b → Bool';
};

subtest 'string ne → Bool' => sub {
    my $t = infer_stmt('$a ne $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a ne $b → Bool';
};

subtest 'string lt → Bool' => sub {
    my $t = infer_stmt('$a lt $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a lt $b → Bool';
};

subtest 'string gt → Bool' => sub {
    my $t = infer_stmt('$a gt $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a gt $b → Bool';
};

subtest 'string le → Bool' => sub {
    my $t = infer_stmt('$a le $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a le $b → Bool';
};

subtest 'string ge → Bool' => sub {
    my $t = infer_stmt('$a ge $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a ge $b → Bool';
};

subtest 'string cmp → Bool' => sub {
    my $t = infer_stmt('$a cmp $b;');
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a cmp $b → Bool';
};

# ── Logical Negation ────────────────────────────

subtest 'logical not (!) → Bool' => sub {
    my $t = infer_stmt('!$a;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Bool', '!$a → Bool';
};

subtest 'logical not (not) → Bool' => sub {
    my $t = infer_stmt('not $a;');
    ok $t, 'inferred';
    is $t->name, 'Bool', 'not $a → Bool';
};

# ── Logical Operators ───────────────────────────

subtest 'logical and (&&) → left operand type' => sub {
    my $env = +{ variables => +{ '$a' => Typist::Type::Atom->new('Int') } };
    my $t = infer_stmt('$a && $b;', $env);
    ok $t, 'inferred';
    is $t->name, 'Int', '$a && $b → Int (left operand type)';
};

subtest 'logical or (||) → left operand type' => sub {
    my $env = +{ variables => +{ '$a' => Typist::Type::Atom->new('Str') } };
    my $t = infer_stmt('$a || $b;', $env);
    ok $t, 'inferred';
    is $t->name, 'Str', '$a || $b → Str (left operand type)';
};

subtest 'defined-or (//) → left operand type' => sub {
    my $env = +{ variables => +{ '$a' => Typist::Type::Atom->new('Num') } };
    my $t = infer_stmt('$a // $b;', $env);
    ok $t, 'inferred';
    is $t->name, 'Num', '$a // $b → Num (left operand type)';
};

subtest 'logical and (and) → left operand type' => sub {
    my $env = +{ variables => +{ '$a' => Typist::Type::Atom->new('Bool') } };
    my $t = infer_stmt('$a and $b;', $env);
    ok $t, 'inferred';
    is $t->name, 'Bool', '$a and $b → Bool (left operand type)';
};

subtest 'logical or (or) → left operand type' => sub {
    my $env = +{ variables => +{ '$a' => Typist::Type::Atom->new('Int') } };
    my $t = infer_stmt('$a or $b;', $env);
    ok $t, 'inferred';
    is $t->name, 'Int', '$a or $b → Int (left operand type)';
};

# ── Logical without env → undef ─────────────────

subtest 'logical and without env → undef' => sub {
    my $t = infer_stmt('$a && $b;');
    is $t, undef, '$a && $b without env → undef';
};

# ── Ternary Operator ─────────────────────────────

subtest 'ternary same type (Str)' => sub {
    my $t = infer_stmt('$x ? "hello" : "world";');
    ok $t, 'inferred';
    is $t->to_string, 'Str', '$x ? "hello" : "world" → Str';
};

subtest 'ternary same type (Int)' => sub {
    my $t = infer_stmt('$x ? 42 : 0;');
    ok $t, 'inferred';
    is $t->to_string, 'Int', '$x ? 42 : 0 → Int';
};

subtest 'ternary different types → Union' => sub {
    my $t = infer_stmt('$x ? "hello" : 42;');
    ok $t, 'inferred';
    ok $t->is_union, 'is union';
    my @m = sort map { $_->to_string } $t->members;
    is_deeply \@m, [qw(Int Str)], '$x ? "hello" : 42 → Str | Int';
};

subtest 'ternary LUB within numeric hierarchy' => sub {
    my $t = infer_stmt('$x ? 3.14 : 42;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom (LUB)';
    is $t->name, 'Num', '$x ? 3.14 : 42 → Num (common_super)';
};

subtest 'ternary one branch non-inferable → undef' => sub {
    my $t = infer_stmt('$x ? $y : 42;');
    is $t, undef, '$x ? $y : 42 → undef (gradual)';
};

# ── Subscript Access ─────────────────────────────

subtest 'array subscript: ArrayRef[Int] → Int' => sub {
    my $env = +{ variables => +{
        '$arr' => Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Int')),
    }};
    my $t = infer_stmt('$arr->[0];', $env);
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Int', '$arr->[0] → Int';
};

subtest 'hash subscript: HashRef[Str, Int] → Int' => sub {
    my $env = +{ variables => +{
        '$hash' => Typist::Type::Param->new('HashRef',
            Typist::Type::Atom->new('Str'), Typist::Type::Atom->new('Int')),
    }};
    my $t = infer_stmt('$hash->{key};', $env);
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Int', '$hash->{key} → Int';
};

subtest 'struct subscript: { name => Str } → Str' => sub {
    my $env = +{ variables => +{
        '$struct' => Typist::Type::Struct->new(
            name => Typist::Type::Atom->new('Str'),
            age  => Typist::Type::Atom->new('Int'),
        ),
    }};
    my $t = infer_stmt('$struct->{name};', $env);
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Str', '$struct->{name} → Str';
};

subtest 'struct subscript: quoted key' => sub {
    my $env = +{ variables => +{
        '$s' => Typist::Type::Struct->new(
            key => Typist::Type::Atom->new('Num'),
        ),
    }};
    my $t = infer_stmt(q{$s->{'key'};}, $env);
    ok $t, 'inferred';
    is $t->name, 'Num', q{$s->{'key'} → Num};
};

subtest 'struct subscript: unknown field → undef' => sub {
    my $env = +{ variables => +{
        '$s' => Typist::Type::Struct->new(
            name => Typist::Type::Atom->new('Str'),
        ),
    }};
    my $t = infer_stmt('$s->{missing};', $env);
    is $t, undef, '$s->{missing} → undef';
};

subtest 'subscript on unknown variable → undef' => sub {
    my $t = infer_stmt('$unknown->[0];');
    is $t, undef, '$unknown->[0] without env → undef';
};

subtest 'subscript on non-container type → undef' => sub {
    my $env = +{ variables => +{
        '$x' => Typist::Type::Atom->new('Int'),
    }};
    my $t = infer_stmt('$x->[0];', $env);
    is $t, undef, '$x->[0] where $x: Int → undef';
};

subtest 'array subscript via Symbol handler (assignment RHS)' => sub {
    my $env = +{ variables => +{
        '$arr' => Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Str')),
    }};
    # infer_from_source finds the RHS token after '=', which is the Symbol $arr
    # The Symbol handler should peek at -> and [0] siblings
    my $doc = PPI::Document->new(\'my $x = $arr->[0];');
    my $stmts = $doc->find('PPI::Statement') || [];
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        for my $i (0 .. $#children) {
            if ($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq '=') {
                my $rhs = $children[$i + 1] // next;
                my $t = Typist::Static::Infer->infer_expr($rhs, $env);
                ok $t, 'inferred via Symbol handler';
                ok $t->is_atom, 'is atom';
                is $t->name, 'Str', '$arr->[0] via Symbol handler → Str';
                return;
            }
        }
    }
    fail 'should have found assignment';
};

# ── Complex expressions → undef (gradual) ───────

subtest 'chained operators → undef' => sub {
    my $t = infer_stmt('$a + $b * $c;');
    is $t, undef, '$a + $b * $c → undef (not 3-element pattern)';
};

done_testing;
