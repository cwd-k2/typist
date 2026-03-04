use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;
use Typist::Subtype;
use Typist::Registry;
use Typist::Type::Atom;
use Typist::Type::Var;
use Typist::Type::Func;
use Typist::Type::Row;
use Typist::Type::Literal;
use Typist::Type::Record;
use Typist::Type::Struct;
use Typist::Type::Param;
use Typist::Type::Quantified;

sub parse { Typist::Parser->parse(@_) }
sub is_sub { Typist::Subtype->is_subtype(@_) }
sub lub { Typist::Subtype->common_super(@_) }

# ── Void semantics ──────────────────────────────

subtest 'Void semantics' => sub {
    ok !is_sub(parse('Void'), parse('Int')),   'Void </: Int';
    ok !is_sub(parse('Void'), parse('Str')),   'Void </: Str';
    ok !is_sub(parse('Void'), parse('Num')),   'Void </: Num';
    ok !is_sub(parse('Void'), parse('Bool')),  'Void </: Bool';
    ok !is_sub(parse('Void'), parse('Undef')), 'Void </: Undef';
    ok  is_sub(parse('Void'), parse('Any')),   'Void <: Any';
    ok  is_sub(parse('Void'), parse('Void')),  'Void <: Void (identity)';
    ok !is_sub(parse('Int'),  parse('Void')),  'Int </: Void';
    ok !is_sub(parse('Str'),  parse('Void')),  'Str </: Void';
    ok !is_sub(parse('Any'),  parse('Void')),  'Any </: Void';

    # Void <: Union containing Void
    ok  is_sub(parse('Void'), parse('Void | Int')),  'Void <: Void | Int';
    ok  is_sub(parse('Void'), parse('Void | Str')),  'Void <: Void | Str';
};

# ── Never exhaustive ────────────────────────────

subtest 'Never exhaustive coverage' => sub {
    ok  is_sub(parse('Never'), parse('Void')),  'Never <: Void';
    ok  is_sub(parse('Never'), parse('Double')), 'Never <: Double';
    ok  is_sub(parse('Never'), parse('{ name => Str }')), 'Never <: Record';
    ok  is_sub(parse('Never'), parse('(Int) -> Str')),    'Never <: Func';
    ok !is_sub(parse('Void'),  parse('Never')),           'Void </: Never';
    ok !is_sub(parse('Undef'), parse('Never')),           'Undef </: Never';
};

# ── Func multi-stage contravariance ─────────────

subtest 'Func multi-stage contravariance' => sub {
    # CodeRef[Any -> Never] <: CodeRef[Int -> Str]
    # because: Int <: Any (param contra), Never <: Str (return cov)
    my $wide_in_narrow_out = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Any')],
        Typist::Type::Atom->new('Never'),
    );
    my $narrow_in_wide_out = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Int')],
        Typist::Type::Atom->new('Str'),
    );
    ok is_sub($wide_in_narrow_out, $narrow_in_wide_out),
        'CodeRef[Any -> Never] <: CodeRef[Int -> Str]';

    # Reverse should not hold
    ok !is_sub($narrow_in_wide_out, $wide_in_narrow_out),
        'CodeRef[Int -> Str] </: CodeRef[Any -> Never]';

    # Multi-param contravariance: (Num, Any) -> Bool <: (Int, Str) -> Int
    my $f1 = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Num'), Typist::Type::Atom->new('Any')],
        Typist::Type::Atom->new('Bool'),
    );
    my $f2 = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Int'), Typist::Type::Atom->new('Str')],
        Typist::Type::Atom->new('Int'),
    );
    ok is_sub($f1, $f2), '(Num, Any) -> Bool <: (Int, Str) -> Int';
    ok !is_sub($f2, $f1), 'reverse does not hold';
};

# ── Func + effects ──────────────────────────────

subtest 'Func with effects subtyping' => sub {
    # Pure <: Pure
    my $pure1 = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Int')],
        Typist::Type::Atom->new('Int'),
    );
    my $pure2 = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Int')],
        Typist::Type::Atom->new('Int'),
    );
    ok is_sub($pure1, $pure2), 'pure <: pure';

    # Effectful vs pure: should fail (one pure, one not)
    my $eff_row = Typist::Type::Row->new(labels => ['IO']);
    my $effectful = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Int')],
        Typist::Type::Atom->new('Int'),
        $eff_row,
    );
    ok !is_sub($effectful, $pure1), 'effectful </: pure';
    ok !is_sub($pure1, $effectful), 'pure </: effectful';

    # Effects covariance: ![IO, Console] <: ![IO] (more labels <: fewer labels)
    my $io_console = Typist::Type::Row->new(labels => ['IO', 'Console']);
    my $io_only    = Typist::Type::Row->new(labels => ['IO']);
    my $f_ic = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Int')],
        Typist::Type::Atom->new('Int'),
        $io_console,
    );
    my $f_io = Typist::Type::Func->new(
        [Typist::Type::Atom->new('Int')],
        Typist::Type::Atom->new('Int'),
        $io_only,
    );
    ok is_sub($f_ic, $f_io), '![IO, Console] <: ![IO]';
    ok !is_sub($f_io, $f_ic), '![IO] </: ![IO, Console]';
};

# ── Quantified instantiation ───────────────────

subtest 'Quantified instantiation' => sub {
    # forall A. A -> A  <:  Int -> Int
    my $forall_id = parse('forall A. A -> A');
    my $int_to_int = parse('(Int) -> Int');
    ok is_sub($forall_id, $int_to_int), 'forall A. A->A <: Int->Int';

    # forall A. A -> A  <:  Str -> Str
    my $str_to_str = parse('(Str) -> Str');
    ok is_sub($forall_id, $str_to_str), 'forall A. A->A <: Str->Str';

    # Concrete </: forall
    ok !is_sub($int_to_int, $forall_id), 'Int->Int </: forall A. A->A';
};

# ── Quantified subsumption ──────────────────────

subtest 'Quantified subsumption' => sub {
    # forall A. A -> A  <:  forall B. B -> B (same shape)
    my $fa = parse('forall A. A -> A');
    my $fb = parse('forall B. B -> B');
    ok is_sub($fa, $fb), 'forall A. A->A <: forall B. B->B';
    ok is_sub($fb, $fa), 'forall B. B->B <: forall A. A->A';

    # Bounded: forall A: Num. A -> A  <:  forall B: Int. B -> B
    # Contra bounds: sub's bound Num is wider than super's Int, so super's bound Int <: sub's bound Num
    my $bounded_num = Typist::Type::Quantified->new(
        vars => [{ name => 'A', bound => Typist::Type::Atom->new('Num') }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('A')],
            Typist::Type::Var->new('A'),
        ),
    );
    my $bounded_int = Typist::Type::Quantified->new(
        vars => [{ name => 'B', bound => Typist::Type::Atom->new('Int') }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('B')],
            Typist::Type::Var->new('B'),
        ),
    );
    ok is_sub($bounded_num, $bounded_int),
        'forall A:Num. A->A <: forall B:Int. B->B (contra bounds)';
    ok !is_sub($bounded_int, $bounded_num),
        'forall B:Int. B->B </: forall A:Num. A->A (bound violation)';
};

# ── Row subtyping ───────────────────────────────

subtest 'Row subtyping' => sub {
    my $abc = Typist::Type::Row->new(labels => [qw(A B C)]);
    my $ab  = Typist::Type::Row->new(labels => [qw(A B)]);
    my $ba  = Typist::Type::Row->new(labels => [qw(B A)]);
    my $a   = Typist::Type::Row->new(labels => [qw(A)]);

    # More labels <: fewer labels
    ok is_sub($abc, $ab), 'Row(A,B,C) <: Row(A,B)';
    ok is_sub($abc, $a),  'Row(A,B,C) <: Row(A)';
    ok !is_sub($ab, $abc), 'Row(A,B) </: Row(A,B,C)';

    # Order irrelevant (labels are sorted at construction)
    ok is_sub($ab, $ba), 'Row(A,B) <: Row(B,A) (order irrelevant)';
    ok is_sub($ba, $ab), 'Row(B,A) <: Row(A,B)';

    # Identity
    ok is_sub($ab, $ab), 'Row(A,B) <: Row(A,B) (identity)';

    # Empty row
    my $empty = Typist::Type::Row->new(labels => []);
    ok is_sub($abc, $empty), 'Row(A,B,C) <: Row()';
    ok is_sub($empty, $empty), 'Row() <: Row()';
};

# ── Generic struct variance ─────────────────────

subtest 'Generic struct variance' => sub {
    Typist::Registry->reset;

    my $int = Typist::Type::Atom->new('Int');
    my $bool = Typist::Type::Atom->new('Bool');
    my $str = Typist::Type::Atom->new('Str');

    my $record = Typist::Type::Record->new(val => $int);

    my $box_int = Typist::Type::Struct->new(
        name => 'Box', record => $record, package => 'Typist::Struct::Box',
        type_params => ['T'], type_args => [$int],
    );
    my $box_bool = Typist::Type::Struct->new(
        name => 'Box', record => $record, package => 'Typist::Struct::Box',
        type_params => ['T'], type_args => [$bool],
    );
    my $box_str = Typist::Type::Struct->new(
        name => 'Box', record => $record, package => 'Typist::Struct::Box',
        type_params => ['T'], type_args => [$str],
    );

    ok is_sub($box_bool, $box_int),  'Box[Bool] <: Box[Int] (covariant)';
    ok !is_sub($box_int, $box_bool), 'Box[Int] </: Box[Bool]';
    ok !is_sub($box_str, $box_int),  'Box[Str] </: Box[Int]';
    ok is_sub($box_int, $box_int),   'Box[Int] <: Box[Int] (identity)';
};

# ── Literal precision ──────────────────────────

subtest 'Literal precision' => sub {
    my $lit42  = Typist::Type::Literal->new(42, 'Int');
    my $lit42b = Typist::Type::Literal->new(42, 'Int');
    my $lit7   = Typist::Type::Literal->new(7, 'Int');
    my $int    = Typist::Type::Atom->new('Int');
    my $num    = Typist::Type::Atom->new('Num');
    my $str    = Typist::Type::Atom->new('Str');
    my $lit_s  = Typist::Type::Literal->new("hello", 'Str');

    # Literal <: base atom
    ok is_sub($lit42, $int), 'Literal(42,Int) <: Int';
    ok is_sub($lit42, $num), 'Literal(42,Int) <: Num (transitive)';

    # Literal identity
    ok is_sub($lit42, $lit42b), 'Literal(42) <: Literal(42) (same value)';

    # Different values
    ok !is_sub($lit42, $lit7), 'Literal(42) </: Literal(7)';
    ok !is_sub($lit7, $lit42), 'Literal(7) </: Literal(42)';

    # Atom </: Literal
    ok !is_sub($int, $lit42), 'Int </: Literal(42)';

    # String literal
    ok is_sub($lit_s, $str),   'Literal("hello",Str) <: Str';
    ok !is_sub($lit_s, $int),  'Literal("hello",Str) </: Int';
    ok !is_sub($lit42, $lit_s), 'Literal(42,Int) </: Literal("hello",Str)';
};

# ── Placeholder _ in LUB ───────────────────────

subtest 'Placeholder _ in LUB' => sub {
    my $placeholder = Typist::Type::Atom->new('_');
    my $int = parse('Int');
    my $str = parse('Str');

    is lub($int, $placeholder)->to_string, 'Int',
        'common_super(Int, _) = Int';
    is lub($placeholder, $str)->to_string, 'Str',
        'common_super(_, Str) = Str';

    # Param-level placeholder
    my $opt_str = parse('ArrayRef[Str]');
    my $opt_placeholder = Typist::Type::Param->new('ArrayRef', $placeholder);
    my $result = lub($opt_str, $opt_placeholder);
    ok $result->is_param, 'LUB of ArrayRef[Str] and ArrayRef[_] is Param';
    is(($result->params)[0]->to_string, 'Str',
        'common_super(ArrayRef[Str], ArrayRef[_]) = ArrayRef[Str]');
};

# ── Record <: HashRef ──────────────────────────

subtest 'Record <: HashRef' => sub {
    Typist::Registry->reset;

    my $record = parse('{ name => Str, age => Str }');
    my $hashref_str = parse('HashRef[Str, Str]');

    ok is_sub($record, $hashref_str),
        'Record { name => Str, age => Str } <: HashRef[Str, Str]';

    # Width: different value types should fail
    my $record_mixed = parse('{ name => Str, count => Int }');
    ok !is_sub($record_mixed, $hashref_str),
        'Record { name => Str, count => Int } </: HashRef[Str, Str]';

    # Empty record <: HashRef (vacuous truth)
    my $empty_record = Typist::Type::Record->new();
    ok is_sub($empty_record, $hashref_str),
        'empty Record {} <: HashRef[Str, Str]';

    # Covariant value: Int <: Num
    my $record_ints = parse('{ x => Int, y => Int }');
    my $hashref_num = parse('HashRef[Str, Num]');
    ok is_sub($record_ints, $hashref_num),
        'Record { x => Int, y => Int } <: HashRef[Str, Num]';
};

# ── Record LUB ──────────────────────────────────

subtest 'Record LUB' => sub {
    # Common required fields: LUB of types
    my $r1 = parse('{ name => Str, age => Int }');
    my $r2 = parse('{ name => Str, age => Bool }');
    my $result = lub($r1, $r2);
    ok $result->is_record, 'LUB of records is record';
    my %req = $result->required_fields;
    is $req{name}->to_string, 'Str', 'name: Str (identical)';
    is $req{age}->to_string, 'Int', 'age: LUB(Int, Bool) = Int';

    # Disjoint required → optional
    my $ra = parse('{ x => Int }');
    my $rb = parse('{ y => Str }');
    my $lub_ab = lub($ra, $rb);
    ok $lub_ab->is_record, 'LUB of disjoint records is record';
    my %opt = $lub_ab->optional_fields;
    ok exists $opt{x}, 'x becomes optional';
    ok exists $opt{y}, 'y becomes optional';

    # Required + optional promotion
    my $rc = parse('{ x => Int, y => Str }');
    my $rd = parse('{ x => Int, y? => Str }');
    my $lub_cd = lub($rc, $rd);
    ok $lub_cd->is_record, 'LUB of required/optional is record';
    my %cd_req = $lub_cd->required_fields;
    my %cd_opt = $lub_cd->optional_fields;
    ok exists $cd_req{x}, 'x stays required';
    ok exists $cd_opt{y}, 'y promoted to optional';
};

done_testing;
