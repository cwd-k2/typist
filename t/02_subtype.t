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
    ok  is_sub(parse('Bool'),   parse('Int')),    'Bool <: Int';
    ok  is_sub(parse('Int'),    parse('Double')), 'Int <: Double';
    ok  is_sub(parse('Double'), parse('Num')),    'Double <: Num';
    ok  is_sub(parse('Int'),    parse('Num')),    'Int <: Num (transitive)';
    ok  is_sub(parse('Bool'),   parse('Num')),    'Bool <: Num (transitive)';
    ok  is_sub(parse('Bool'),   parse('Double')), 'Bool <: Double (transitive)';
    ok  is_sub(parse('Num'),    parse('Any')),    'Num <: Any';
    ok  is_sub(parse('Double'), parse('Any')),    'Double <: Any (transitive)';
    ok  is_sub(parse('Str'),    parse('Any')),    'Str <: Any';
    ok  is_sub(parse('Undef'),  parse('Any')),    'Undef <: Any';

    ok !is_sub(parse('Str'),    parse('Int')),    'Str </: Int';
    ok !is_sub(parse('Int'),    parse('Str')),    'Int </: Str';
    ok !is_sub(parse('Num'),    parse('Int')),    'Num </: Int';
    ok !is_sub(parse('Double'), parse('Int')),    'Double </: Int';
    ok !is_sub(parse('Num'),    parse('Double')), 'Num </: Double';
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

# ── Optional struct fields ──────────────────────

subtest 'optional struct subtyping' => sub {
    # { name: Str, age: Int } <: { name: Str, age?: Int }
    ok is_sub(
        parse('{ name => Str, age => Int }'),
        parse('{ name => Str, age? => Int }'),
    ), 'required field satisfies optional';

    # { name: Str } <: { name: Str, age?: Int }
    ok is_sub(
        parse('{ name => Str }'),
        parse('{ name => Str, age? => Int }'),
    ), 'missing optional field is ok';

    # { name: Str, age?: Int } </: { name: Str, age: Int }
    ok !is_sub(
        parse('{ name => Str, age? => Int }'),
        parse('{ name => Str, age => Int }'),
    ), 'optional cannot satisfy required';

    # { name: Str, age?: Num } <: { name: Str, age?: Int }  iff Num <: Int? No.
    ok !is_sub(
        parse('{ name => Str, age? => Num }'),
        parse('{ name => Str, age? => Int }'),
    ), 'optional field type must be compatible';

    # { name: Str, age?: Int } <: { name: Str, age?: Num }
    ok is_sub(
        parse('{ name => Str, age? => Int }'),
        parse('{ name => Str, age? => Num }'),
    ), 'optional field covariance';
};

# ── Never (bottom type) ─────────────────────────

subtest 'Never is bottom type' => sub {
    ok  is_sub(parse('Never'), parse('Int')),           'Never <: Int';
    ok  is_sub(parse('Never'), parse('Str')),           'Never <: Str';
    ok  is_sub(parse('Never'), parse('Num')),           'Never <: Num';
    ok  is_sub(parse('Never'), parse('Bool')),          'Never <: Bool';
    ok  is_sub(parse('Never'), parse('Any')),           'Never <: Any';
    ok  is_sub(parse('Never'), parse('Undef')),         'Never <: Undef';
    ok  is_sub(parse('Never'), parse('ArrayRef[Int]')), 'Never <: ArrayRef[Int]';
    ok  is_sub(parse('Never'), parse('Int | Str')),     'Never <: Int|Str';
    ok  is_sub(parse('Never'), parse('Never')),         'Never <: Never (identity)';

    ok !is_sub(parse('Int'),   parse('Never')),         'Int </: Never';
    ok !is_sub(parse('Str'),   parse('Never')),         'Str </: Never';
    ok !is_sub(parse('Any'),   parse('Never')),         'Any </: Never';
};

# ── Alias resolution ─────────────────────────────

subtest 'alias subtype' => sub {
    Typist::Registry->reset;
    Typist::Registry->define_alias('UserId', 'Int');

    ok is_sub(parse('UserId'), parse('Num')), 'UserId (=Int) <: Num';
    ok is_sub(parse('Bool'),   parse('UserId')), 'Bool <: UserId (=Int)';
};

# ── Struct ↔ Param bridge ───────────────────────

subtest 'struct vs param subtyping' => sub {
    Typist::Registry->reset;

    # Set up a generic struct type
    require Typist::Type::Struct;
    require Typist::Type::Record;
    require Typist::Type::Atom;
    require Typist::Type::Param;
    require Typist::Type::Alias;

    my $int = Typist::Type::Atom->new('Int');
    my $str = Typist::Type::Atom->new('Str');

    my $record = Typist::Type::Record->new(val => $int);
    my $struct = Typist::Type::Struct->new(
        name        => 'Box',
        record      => $record,
        package     => 'Typist::Struct::Box',
        type_params => ['T'],
        type_args   => [$int],
    );

    # Param with Alias base (as produced by Parser for :sig())
    my $param = Typist::Type::Param->new(
        Typist::Type::Alias->new('Box'), $int,
    );

    # Param with string base
    my $param_str = Typist::Type::Param->new('Box', $int);

    ok is_sub($struct, $param),     'Struct[Int] <: Param(Box, [Int])';
    ok is_sub($param, $struct),     'Param(Box, [Int]) <: Struct[Int]';
    ok is_sub($param_str, $struct), 'Param(str "Box", [Int]) <: Struct[Int]';

    # Mismatched type args
    my $param_str2 = Typist::Type::Param->new(
        Typist::Type::Alias->new('Box'), $str,
    );
    ok !is_sub($struct, $param_str2), 'Struct Box[Int] </: Param Box[Str]';
    ok !is_sub($param_str2, $struct), 'Param Box[Str] </: Struct Box[Int]';

    # Covariant: Box[Bool] <: Box[Int] via Param
    my $bool = Typist::Type::Atom->new('Bool');
    my $struct_bool = Typist::Type::Struct->new(
        name        => 'Box',
        record      => $record,
        package     => 'Typist::Struct::Box',
        type_params => ['T'],
        type_args   => [$bool],
    );
    ok is_sub($struct_bool, $param), 'Struct Box[Bool] <: Param Box[Int] (covariance)';
};

done_testing;
