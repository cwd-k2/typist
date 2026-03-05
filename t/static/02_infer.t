use v5.40;
use Test::More;
use lib 'lib';

use PPI;
use Typist::Static::Infer;
use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Record;

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
    is $t->base_type, 'Double', '3.14 → Literal(Double)';
};

subtest 'int literal 0' => sub {
    my $t = infer_from_source('my $x = 0;');
    ok $t, 'inferred';
    is $t->base_type, 'Int', '0 → Literal(Int)';
};

subtest 'int literal 1' => sub {
    my $t = infer_from_source('my $x = 1;');
    ok $t, 'inferred';
    is $t->base_type, 'Int', '1 → Literal(Int)';
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

subtest 'array of mixed ints' => sub {
    my $t = infer_from_source('my $x = [0, 1, 5];');
    ok $t, 'inferred';
    my @p = $t->params;
    is $p[0]->name, 'Int', '0 + 1 + 5 → Int';
};

# ── Hash Constructor ─────────────────────────────

subtest 'hash with string values → Struct' => sub {
    my $doc = PPI::Document->new(\'my $x = +{ a => "foo", b => "bar" };');
    my $cons = $doc->find_first('PPI::Structure::Constructor');
    ok $cons, 'found constructor';
    my $t = Typist::Static::Infer->infer_expr($cons);
    ok $t, 'inferred';
    ok $t->is_record, 'is struct (not HashRef)';
    my %req = $t->required_fields;
    is $req{a}->base_type, 'Str', 'a => Str (literal)';
    is $req{b}->base_type, 'Str', 'b => Str (literal)';
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
    is $t->name, 'Double', '$x ? 3.14 : 42 → Double (common_super)';
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
        '$struct' => Typist::Type::Record->new(
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
        '$s' => Typist::Type::Record->new(
            key => Typist::Type::Atom->new('Num'),
        ),
    }};
    my $t = infer_stmt(q{$s->{'key'};}, $env);
    ok $t, 'inferred';
    is $t->name, 'Num', q{$s->{'key'} → Num};
};

subtest 'struct subscript: unknown field → undef' => sub {
    my $env = +{ variables => +{
        '$s' => Typist::Type::Record->new(
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

# ── Subscript Chain ──────────────────────────────

subtest 'chained struct subscript: $s->{a}->{b}' => sub {
    my $env = +{ variables => +{
        '$order' => Typist::Type::Record->new(
            id     => Typist::Type::Atom->new('Int'),
            item   => Typist::Type::Record->new(
                name  => Typist::Type::Atom->new('Str'),
                price => Typist::Type::Atom->new('Num'),
            ),
        ),
    }};
    my $t = infer_stmt('$order->{item}->{name};', $env);
    ok $t, 'inferred nested struct field';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Str', '$order->{item}->{name} → Str';
};

subtest 'function call chain: func()->{field}' => sub {
    my $env = +{
        variables => +{},
        functions => +{
            get_order => Typist::Type::Record->new(
                id    => Typist::Type::Atom->new('Int'),
                total => Typist::Type::Atom->new('Num'),
            ),
        },
        known => +{ get_order => 1 },
    };
    my $t = infer_stmt('get_order()->{total};', $env);
    ok $t, 'inferred function call chain';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Num', 'get_order()->{total} → Num';
};

subtest 'chained array then struct: $arr->[0]->{name}' => sub {
    my $env = +{ variables => +{
        '$arr' => Typist::Type::Param->new('ArrayRef',
            Typist::Type::Record->new(
                name => Typist::Type::Atom->new('Str'),
            ),
        ),
    }};
    my $t = infer_stmt('$arr->[0]->{name};', $env);
    ok $t, 'inferred array→struct chain';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Str', '$arr->[0]->{name} → Str';
};

# ── Complex expressions → undef (gradual) ───────

subtest 'chained mixed operators' => sub {
    my $t = infer_stmt('$a + $b * $c;');
    ok $t, 'inferred mixed arithmetic';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Num', '$a + $b * $c → Num (unknown vars)';
};

subtest 'mixed comparison+logical → Bool' => sub {
    my $t = infer_stmt('$a >= $b && $a <= $c;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Bool', '$a >= $b && $a <= $c → Bool';
};

subtest 'arithmetic precision: Int + Int → Int' => sub {
    my $t = infer_stmt('42 + 3;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Int', '42 + 3 → Int';
};

subtest 'arithmetic precision: Int + Double → Double' => sub {
    my $t = infer_stmt('42 + 3.14;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Double', '42 + 3.14 → Double';
};

subtest 'arithmetic precision: Int - Int → Int' => sub {
    my $t = infer_stmt('100 - 50;');
    ok $t, 'inferred';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Int', '100 - 50 → Int';
};

# ── Bidirectional (expected-guided) inference ────

subtest 'expected-guided array inference' => sub {
    my $source = '[1, 2, 3]';
    my $doc = PPI::Document->new(\$source);
    my $cons = $doc->find_first('PPI::Structure::Constructor');

    my $expected = Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Int'));
    my $result = Typist::Static::Infer->infer_expr($cons, undef, $expected);
    ok $result, 'got result with expected';
    is $result->to_string, 'ArrayRef[Int]', 'expected guided array inference';
};

subtest 'expected does not override actual literal' => sub {
    my $source = '42';
    my $doc = PPI::Document->new(\$source);
    my $num = $doc->find_first('PPI::Token::Number');

    my $expected = Typist::Type::Atom->new('Str');
    my $result = Typist::Static::Infer->infer_expr($num, undef, $expected);
    ok $result, 'got result';
    like $result->to_string, qr/42|Int/, 'expected does not override literal';
};

subtest 'expected propagates to ternary arms' => sub {
    my $t = infer_stmt('$x ? "hello" : "world";');
    ok $t, 'inferred without expected';
    is $t->to_string, 'Str', 'ternary same type (baseline)';

    # With expected — result should still be Str (same type both arms)
    my $doc = PPI::Document->new(\'$x ? "hello" : "world";');
    my $stmt = $doc->find_first('PPI::Statement');
    my $expected = Typist::Type::Atom->new('Str');
    my $result = Typist::Static::Infer->infer_expr($stmt, undef, $expected);
    ok $result, 'got result with expected';
    is $result->to_string, 'Str', 'ternary with expected hint';
};

subtest 'expected=undef backward compatible' => sub {
    # Ensure existing 2-arg calls still work
    my $source = '42';
    my $doc = PPI::Document->new(\$source);
    my $num = $doc->find_first('PPI::Token::Number');
    my $result = Typist::Static::Infer->infer_expr($num);
    ok $result, 'works without expected';
    ok $result->is_literal, 'still infers literal';
};

subtest 'expected struct propagates to hash values' => sub {
    my $doc = PPI::Document->new(\'my $x = +{ name => "Alice", items => [1, 2] };');
    my $cons = $doc->find_first('PPI::Structure::Constructor');
    ok $cons, 'found constructor';

    my $expected = Typist::Type::Record->new(
        name  => Typist::Type::Atom->new('Str'),
        items => Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Int')),
    );
    my $result = Typist::Static::Infer->infer_expr($cons, undef, $expected);
    ok $result, 'got result with struct expected';
    ok $result->is_record, 'result is struct';
    my %req = $result->required_fields;
    ok $req{name}, 'has name field';
    ok $req{items}, 'has items field';
    is $req{items}->to_string, 'ArrayRef[Int]', 'items field inferred as ArrayRef[Int]';
};

# ── Anonymous Sub Inference ────────────────────────

use Typist::Type::Func;

subtest 'anonymous sub: no expected type → generic Func' => sub {
    my $doc = PPI::Document->new(\'my $f = sub ($x) { 42 };');
    my $sub_word = $doc->find_first(sub {
        $_[1]->isa('PPI::Token::Word') && $_[1]->content eq 'sub'
    });
    ok $sub_word, 'found sub keyword';
    my $t = Typist::Static::Infer->infer_expr($sub_word);
    ok $t, 'inferred';
    ok $t->is_func, 'is Func type';
    is scalar($t->params), 1, 'has 1 parameter';
};

subtest 'anonymous sub: 2 params → Func with 2 params' => sub {
    my $doc = PPI::Document->new(\'my $f = sub ($x, $y) { $x };');
    my $sub_word = $doc->find_first(sub {
        $_[1]->isa('PPI::Token::Word') && $_[1]->content eq 'sub'
    });
    my $t = Typist::Static::Infer->infer_expr($sub_word);
    ok $t && $t->is_func, 'inferred as Func';
    is scalar($t->params), 2, 'has 2 parameters';
};

subtest 'anonymous sub: no signature → 0 params' => sub {
    my $doc = PPI::Document->new(\'my $f = sub { 42 };');
    my $sub_word = $doc->find_first(sub {
        $_[1]->isa('PPI::Token::Word') && $_[1]->content eq 'sub'
    });
    my $t = Typist::Static::Infer->infer_expr($sub_word);
    ok $t && $t->is_func, 'inferred as Func';
    is scalar($t->params), 0, 'has 0 parameters';
};

subtest 'anonymous sub: expected Func propagates param types' => sub {
    my $doc = PPI::Document->new(\'my $f = sub ($x) { $x };');
    my $sub_word = $doc->find_first(sub {
        $_[1]->isa('PPI::Token::Word') && $_[1]->content eq 'sub'
    });
    my $expected = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Int')],
        Typist::Type::Atom->new('Int'),
    );
    my $t = Typist::Static::Infer->infer_expr($sub_word, undef, $expected);
    ok $t && $t->is_func, 'inferred as Func';
    is scalar($t->params), 1, 'has 1 parameter';
    is(($t->params)[0]->to_string, 'Int', 'param type propagated from expected');
};

subtest 'anonymous sub: arity mismatch with expected → generic params' => sub {
    my $doc = PPI::Document->new(\'my $f = sub ($x, $y) { $x };');
    my $sub_word = $doc->find_first(sub {
        $_[1]->isa('PPI::Token::Word') && $_[1]->content eq 'sub'
    });
    # Expected 1 param, actual 2 params
    my $expected = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Int')],
        Typist::Type::Atom->new('Int'),
    );
    my $t = Typist::Static::Infer->infer_expr($sub_word, undef, $expected);
    ok $t && $t->is_func, 'inferred as Func';
    is scalar($t->params), 2, 'has 2 params (actual count, not expected)';
    is(($t->params)[0]->to_string, 'Any', 'param type is Any (arity mismatch)');
};

# ── Unwrap Inference ──────────────────────────────

use Typist::Registry;
use Typist::Type::Newtype;
use Typist::Type::Alias;

subtest 'UserId::coerce infers newtype inner type' => sub {
    my $registry = Typist::Registry->new;
    my $inner = Typist::Type::Atom->new('Int');
    my $type  = Typist::Type::Newtype->new('UserId', $inner);
    $registry->register_newtype('UserId', $type);
    $registry->register_function('UserId', 'coerce', +{
        params       => [$type],
        returns      => $inner,
        generics     => [],
        params_expr  => ['UserId'],
        returns_expr => 'Int',
    });

    my $env = +{
        variables => +{ '$uid' => Typist::Type::Alias->new('UserId') },
        functions => +{},
        known     => +{},
        registry  => $registry,
        package   => 'main',
    };

    # UserId::coerce($uid) → Int
    my $doc = PPI::Document->new(\'UserId::coerce($uid)');
    my $sym = $doc->find_first('PPI::Token::Word');
    ok $sym, 'found UserId::coerce word';
    my $t = Typist::Static::Infer->infer_expr($sym, $env);
    ok $t, 'inferred from coerce call';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Int', 'UserId::coerce($uid) → Int';
};

subtest 'coerce through alias chain resolves to newtype inner' => sub {
    # newtype UserId => Int, typedef MyId => UserId
    my $registry = Typist::Registry->new;
    my $inner = Typist::Type::Atom->new('Int');
    my $type  = Typist::Type::Newtype->new('UserId', $inner);
    $registry->register_newtype('UserId', $type);
    $registry->register_function('UserId', 'coerce', +{
        params       => [$type],
        returns      => $inner,
        generics     => [],
        params_expr  => ['UserId'],
        returns_expr => 'Int',
    });
    $registry->define_alias('MyId', 'UserId');

    my $env = +{
        variables => +{ '$id' => Typist::Type::Alias->new('MyId') },
        functions => +{},
        known     => +{},
        registry  => $registry,
        package   => 'main',
    };

    # UserId::coerce($id) where $id: MyId → UserId → Int
    my $doc = PPI::Document->new(\'UserId::coerce($id)');
    my $sym = $doc->find_first('PPI::Token::Word');
    my $t = Typist::Static::Infer->infer_expr($sym, $env);
    ok $t, 'inferred through alias chain';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Int', 'UserId::coerce($id) → Int (alias → newtype → inner)';
};

# ── infer_expr_with_siblings ────────────────────

# Helper: parse a `my $x = EXPR;` statement and call infer_expr_with_siblings
# on the init_node (first token after '=').
sub infer_with_siblings ($source, $env = undef) {
    my $doc = PPI::Document->new(\$source);
    my $stmts = $doc->find('PPI::Statement') || [];
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        for my $i (0 .. $#children) {
            if ($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq '=') {
                my $rhs = $children[$i + 1] // next;
                return Typist::Static::Infer->infer_expr_with_siblings($rhs, $env);
            }
        }
    }
    undef;
}

subtest 'sibling: string x operator → Str' => sub {
    my $t = infer_with_siblings('my $pad = "  " x $indent;');
    ok $t, 'inferred type for "  " x $indent';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Str', '"  " x $indent → Str';
};

subtest 'sibling: string concatenation → Str' => sub {
    my $env = +{
        variables => +{ '$a' => Typist::Type::Atom->new('Str') },
        functions => +{},
        known     => +{},
    };
    my $t = infer_with_siblings('my $s = $a . "suffix";', $env);
    ok $t, 'inferred type for $a . "suffix"';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Str', '$a . "suffix" → Str';
};

subtest 'sibling: arithmetic → Int (literal LUB)' => sub {
    my $t = infer_with_siblings('my $n = 42 + 3;');
    ok $t, 'inferred type for 42 + 3';
    ok $t->is_atom, 'is atom';
    is $t->name, 'Int', '42 + 3 → Int (both Int literals)';
};

subtest 'sibling: no operator → falls through to infer_expr' => sub {
    my $t = infer_with_siblings('my $x = "hello";');
    ok $t, 'inferred type for plain string';
    ok $t->is_literal, 'is literal (no sibling op)';
    is $t->value, 'hello', 'preserves Literal["hello"]';
};

subtest 'sibling: fat comma (=>) is not a binary operator' => sub {
    # In `log => sub { ... }`, "log" followed by "=>" should NOT trigger binop
    my $t = infer_with_siblings('my $x = "key";');
    ok $t, 'plain token inferred';
    # The point is: => after a word would be a hash key, not an operator expression.
    # We test by confirming that => is excluded in the method:
    my $doc = PPI::Document->new(\'log => sub { 1 }');
    my $word = $doc->find_first('PPI::Token::Word');
    my $result = Typist::Static::Infer->infer_expr_with_siblings($word);
    ok !defined($result), 'word followed by => returns undef (no binop)';
};

# ── Tuple inference from array literals ──────────

subtest 'tuple: [42, "hello"] with expected Tuple[Int, Str]' => sub {
    my $expected = Typist::Type::Param->new('Tuple',
        Typist::Type::Atom->new('Int'), Typist::Type::Atom->new('Str'));
    my $doc = PPI::Document->new(\'[42, "hello"]');
    my $arr = $doc->find_first('PPI::Structure::Constructor');
    my $t = Typist::Static::Infer->infer_expr($arr, undef, $expected);
    ok $t, 'inferred';
    ok $t->is_param, 'is param';
    is $t->base, 'Tuple', 'base is Tuple';
    my @p = $t->params;
    is scalar @p, 2, '2 params';
    is $p[0]->base_type, 'Int', 'first element Int (literal)';
    is $p[1]->base_type, 'Str', 'second element Str (literal)';
};

subtest 'tuple: [1, "hello"] without expected → ArrayRef' => sub {
    my $doc = PPI::Document->new(\'[1, "hello"]');
    my $arr = $doc->find_first('PPI::Structure::Constructor');
    my $t = Typist::Static::Infer->infer_expr($arr);
    ok $t, 'inferred';
    ok $t->is_param, 'is param';
    is $t->base, 'ArrayRef', 'base is ArrayRef (no Tuple expected)';
};

subtest 'tuple: [] with expected Tuple[Int, Str] → Tuple[Int, Str]' => sub {
    my $expected = Typist::Type::Param->new('Tuple',
        Typist::Type::Atom->new('Int'), Typist::Type::Atom->new('Str'));
    my $doc = PPI::Document->new(\'[]');
    my $arr = $doc->find_first('PPI::Structure::Constructor');
    my $t = Typist::Static::Infer->infer_expr($arr, undef, $expected);
    ok $t, 'inferred';
    is $t->base, 'Tuple', 'empty array with Tuple expected → Tuple';
    my @p = $t->params;
    is scalar @p, 2, 'preserves 2 params from expected';
};

subtest 'tuple: arity mismatch [1, 2, 3] with Tuple[Int, Str] → ArrayRef fallback' => sub {
    my $expected = Typist::Type::Param->new('Tuple',
        Typist::Type::Atom->new('Int'), Typist::Type::Atom->new('Str'));
    my $doc = PPI::Document->new(\'[1, 2, 3]');
    my $arr = $doc->find_first('PPI::Structure::Constructor');
    my $t = Typist::Static::Infer->infer_expr($arr, undef, $expected);
    ok $t, 'inferred';
    is $t->base, 'ArrayRef', 'arity mismatch → ArrayRef fallback';
};

# ── Recursive type alias: _infer_array with alias resolution ──

subtest 'array: alias expected resolves before elem extraction' => sub {
    my $registry = Typist::Registry->new;
    # typedef IntList = Int | ArrayRef[IntList]
    $registry->define_alias('IntList',
        Typist::Type::Union->new(
            Typist::Type::Atom->new('Int'),
            Typist::Type::Param->new('ArrayRef', Typist::Type::Alias->new('IntList')),
        ),
    );

    my $env = +{
        registry  => $registry,
        variables => +{},
        functions => +{},
        known     => +{},
    };

    my $expected = Typist::Type::Alias->new('IntList');
    my $doc = PPI::Document->new(\'[1, 2, 3]');
    my $arr = $doc->find_first('PPI::Structure::Constructor');
    my $t = Typist::Static::Infer->infer_expr($arr, $env, $expected);
    ok $t, 'inferred';
    is $t->base, 'ArrayRef', 'is ArrayRef';
    # The element type should be Int (from literal widening), not Any
    my $elem = ($t->params)[0];
    ok $elem->is_atom && $elem->name eq 'Int', 'element type is Int (not Any)';
};

subtest 'array: Union expected extracts ArrayRef elem type' => sub {
    my $expected = Typist::Type::Union->new(
        Typist::Type::Atom->new('Int'),
        Typist::Type::Param->new('ArrayRef', Typist::Type::Atom->new('Str')),
    );

    my $doc = PPI::Document->new(\'["a", "b"]');
    my $arr = $doc->find_first('PPI::Structure::Constructor');
    my $t = Typist::Static::Infer->infer_expr($arr, undef, $expected);
    ok $t, 'inferred';
    is $t->base, 'ArrayRef', 'is ArrayRef';
};

# ── List assignment RHS inference ─────────────────

subtest 'infer_list_rhs_type: function call via @{func()}' => sub {
    my $ret = Typist::Type::Param->new('Tuple',
        Typist::Type::Atom->new('Int'),
        Typist::Type::Atom->new('Str'),
    );
    my $env = +{
        variables => {},
        functions => { make_pair => $ret },
        known     => { make_pair => 1 },
    };

    my $doc = PPI::Document->new(\'my ($a, $b) = @{make_pair()}');
    my @stmts = $doc->schildren;
    my @children = $stmts[0]->schildren;

    # Find init_node (first token after '=')
    my $init_node;
    for my $i (0 .. $#children) {
        if ($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq '=') {
            $init_node = $children[$i + 1];
            last;
        }
    }
    ok $init_node, 'found init_node';

    my $rhs = Typist::Static::Infer->infer_list_rhs_type($init_node, $env);
    ok $rhs, 'inferred RHS type';
    is $rhs->to_string, 'Tuple[Int, Str]', 'RHS is Tuple[Int, Str]';
};

subtest 'infer_list_rhs_type: direct function call' => sub {
    my $ret = Typist::Type::Param->new('ArrayRef',
        Typist::Type::Atom->new('Int'),
    );
    my $env = +{
        variables => {},
        functions => { get_pair => $ret },
        known     => { get_pair => 1 },
    };

    my $doc = PPI::Document->new(\'my ($a, $b) = get_pair()');
    my @stmts = $doc->schildren;
    my @children = $stmts[0]->schildren;

    my $init_node;
    for my $i (0 .. $#children) {
        if ($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq '=') {
            $init_node = $children[$i + 1];
            last;
        }
    }
    ok $init_node, 'found init_node';

    my $rhs = Typist::Static::Infer->infer_list_rhs_type($init_node, $env);
    ok $rhs, 'inferred RHS type';
    is $rhs->to_string, 'ArrayRef[Int]', 'RHS is ArrayRef[Int]';
};

done_testing;
