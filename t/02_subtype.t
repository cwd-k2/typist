use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;
use Typist::Subtype;
use Typist::Registry;

sub parse { Typist::Parser->parse(@_) }
sub is_sub { Typist::Subtype->is_subtype(@_) }

# ── Primitive hierarchy ──────────────────────────

subtest 'primitive hierarchy' => sub {
    ok  is_sub(parse('Bool'), parse('Int')),   'Bool <: Int';
    ok  is_sub(parse('Int'),  parse('Num')),   'Int <: Num';
    ok  is_sub(parse('Bool'), parse('Num')),   'Bool <: Num (transitive)';
    ok  is_sub(parse('Num'),  parse('Any')),   'Num <: Any';
    ok  is_sub(parse('Str'),  parse('Any')),   'Str <: Any';
    ok  is_sub(parse('Undef'), parse('Any')),  'Undef <: Any';

    ok !is_sub(parse('Str'),  parse('Int')),   'Str </: Int';
    ok !is_sub(parse('Int'),  parse('Str')),   'Int </: Str';
    ok !is_sub(parse('Num'),  parse('Int')),   'Num </: Int';
};

# ── Identity ─────────────────────────────────────

subtest 'identity' => sub {
    ok is_sub(parse('Int'), parse('Int')),           'Int <: Int';
    ok is_sub(parse('ArrayRef[Int]'), parse('ArrayRef[Int]')), 'ArrayRef[Int] <: ArrayRef[Int]';
};

# ── Everything <: Any ─────────────────────────────

subtest 'everything subtypes Any' => sub {
    ok is_sub(parse('Int'),            parse('Any')), 'Int <: Any';
    ok is_sub(parse('ArrayRef[Str]'),  parse('Any')), 'ArrayRef[Str] <: Any';
    ok is_sub(parse('Int | Str'),      parse('Any')), 'Int|Str <: Any';
};

# ── Union subtype rules ──────────────────────────

subtest 'union rules' => sub {
    # T|U <: S  iff  T <: S AND U <: S
    ok  is_sub(parse('Bool | Int'), parse('Num')),  'Bool|Int <: Num';
    ok !is_sub(parse('Int | Str'),  parse('Num')),  'Int|Str </: Num';

    # S <: T|U  iff  S <: T OR S <: U
    ok  is_sub(parse('Int'), parse('Int | Str')),   'Int <: Int|Str';
    ok  is_sub(parse('Str'), parse('Int | Str')),   'Str <: Int|Str';
    ok !is_sub(parse('Num'), parse('Int | Str')),   'Num </: Int|Str';
};

# ── Intersection subtype rules ───────────────────

subtest 'intersection rules' => sub {
    # T&U <: S  iff  T <: S OR U <: S
    ok is_sub(parse('Int & Str'), parse('Num')), 'Int&Str <: Num (via Int)';

    # S <: T&U  iff  S <: T AND S <: U
    ok !is_sub(parse('Int'), parse('Num & Str')), 'Int </: Num&Str';
};

# ── Parameterized covariance ─────────────────────

subtest 'parameterized covariance' => sub {
    ok  is_sub(parse('ArrayRef[Int]'), parse('ArrayRef[Num]')), 'ArrayRef[Int] <: ArrayRef[Num]';
    ok !is_sub(parse('ArrayRef[Num]'), parse('ArrayRef[Int]')), 'ArrayRef[Num] </: ArrayRef[Int]';
    ok  is_sub(parse('ArrayRef[Bool]'), parse('ArrayRef[Num]')), 'ArrayRef[Bool] <: ArrayRef[Num]';
};

# ── Function contravariance ──────────────────────

subtest 'function types' => sub {
    # CodeRef[Num -> Int] <: CodeRef[Int -> Num]
    # because Int <: Num (param contravariant) and Int <: Num (return covariant)
    ok is_sub(
        parse('CodeRef[Num -> Int]'),
        parse('CodeRef[Int -> Num]'),
    ), 'contravariant params, covariant return';

    # CodeRef[Int -> Num] </: CodeRef[Num -> Int]
    ok !is_sub(
        parse('CodeRef[Int -> Num]'),
        parse('CodeRef[Num -> Int]'),
    ), 'reverse is not subtype';
};

# ── Struct width subtyping ───────────────────────

subtest 'struct width subtyping' => sub {
    ok is_sub(
        parse('{ name => Str, age => Int }'),
        parse('{ name => Str }'),
    ), 'wider struct <: narrower struct';

    ok !is_sub(
        parse('{ name => Str }'),
        parse('{ name => Str, age => Int }'),
    ), 'narrower struct </: wider struct';
};

# ── Alias resolution ─────────────────────────────

subtest 'alias subtype' => sub {
    Typist::Registry->reset;
    Typist::Registry->define_alias('UserId', 'Int');

    ok is_sub(parse('UserId'), parse('Num')), 'UserId (=Int) <: Num';
    ok is_sub(parse('Bool'),   parse('UserId')), 'Bool <: UserId (=Int)';
};

done_testing;
