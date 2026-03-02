use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;
use Typist::Subtype;

sub parse  { Typist::Parser->parse(@_) }
sub is_sub { Typist::Subtype->is_subtype(@_) }

# ── Parsing literal types ───────────────────────

subtest 'parse string literals' => sub {
    my $t = parse('"hello"');
    ok $t->is_literal, '"hello" is literal';
    is $t->value, 'hello', 'value is hello';
    is $t->base_type, 'Str', 'base type is Str';
    is $t->to_string, '"hello"', 'to_string';

    my $t2 = parse("'world'");
    ok $t2->is_literal, "'world' is literal";
    is $t2->value, 'world', 'value is world';
};

subtest 'parse numeric literals' => sub {
    my $t = parse('42');
    ok $t->is_literal, '42 is literal';
    is $t->value, 42, 'value is 42';
    is $t->base_type, 'Int', 'base type is Int';
    is $t->to_string, '42', 'to_string';

    my $t2 = parse('3.14');
    ok $t2->is_literal, '3.14 is literal';
    is $t2->value, 3.14, 'value is 3.14';
    is $t2->base_type, 'Double', 'base type is Double';

    my $t3 = parse('-1');
    ok $t3->is_literal, '-1 is literal';
    is $t3->value, -1, 'value is -1';
    is $t3->base_type, 'Int', 'base type is Int';
};

# ── Equality ─────────────────────────────────────

subtest 'literal equality' => sub {
    ok  parse('42')->equals(parse('42')),       '42 == 42';
    ok !parse('42')->equals(parse('43')),       '42 != 43';
    ok  parse('"hi"')->equals(parse('"hi"')),   '"hi" == "hi"';
    ok !parse('"hi"')->equals(parse('"bye"')),  '"hi" != "bye"';
    ok !parse('42')->equals(parse('"42"')),     '42 != "42" (different base)';
};

# ── Contains ────────────────────────────────────

subtest 'literal contains' => sub {
    ok  parse('42')->contains(42),       '42 contains 42';
    ok !parse('42')->contains(43),       '42 does not contain 43';
    ok  parse('"hello"')->contains('hello'), '"hello" contains "hello"';
    ok !parse('"hello"')->contains('world'), '"hello" does not contain "world"';
};

# ── Subtype relations ───────────────────────────

subtest 'literal subtype of base type' => sub {
    ok  is_sub(parse('42'),      parse('Int')),    '42 <: Int';
    ok  is_sub(parse('42'),      parse('Double')), '42 <: Double (transitive)';
    ok  is_sub(parse('42'),      parse('Num')),    '42 <: Num (transitive)';
    ok  is_sub(parse('42'),      parse('Any')),    '42 <: Any';
    ok  is_sub(parse('3.14'),    parse('Double')), '3.14 <: Double';
    ok  is_sub(parse('3.14'),    parse('Num')),    '3.14 <: Num (transitive)';
    ok  is_sub(parse('"hello"'), parse('Str')),    '"hello" <: Str';
    ok  is_sub(parse('"hello"'), parse('Any')),    '"hello" <: Any';

    ok !is_sub(parse('42'),      parse('Str')),  '42 </: Str';
    ok !is_sub(parse('"hello"'), parse('Int')),  '"hello" </: Int';
    ok !is_sub(parse('3.14'),    parse('Int')),  '3.14 </: Int';
};

subtest 'base type not subtype of literal' => sub {
    ok !is_sub(parse('Int'), parse('42')),       'Int </: 42';
    ok !is_sub(parse('Str'), parse('"hello"')),  'Str </: "hello"';
};

subtest 'literal in union' => sub {
    ok  is_sub(parse('42'),      parse('42 | "hello"')),  '42 <: 42|"hello"';
    ok  is_sub(parse('"hello"'), parse('42 | "hello"')),  '"hello" <: 42|"hello"';
    ok !is_sub(parse('43'),      parse('42 | "hello"')),  '43 </: 42|"hello"';
};

subtest 'literal with Never' => sub {
    ok  is_sub(parse('Never'), parse('42')),      'Never <: 42';
    ok  is_sub(parse('Never'), parse('"hello"')), 'Never <: "hello"';
};

done_testing;
