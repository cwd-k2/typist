use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::Analyze qw(analyze type_errors arity_errors all_errors diags_of_kind);

# ════════════════════════════════════════════════
# Section 1: Method Chain Inference
#   Struct accessor chains, derive chains, cross-type chains
# ════════════════════════════════════════════════

# ── 1.1 Two-level accessor chain ──

subtest 'chain: two-level struct accessor' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Address => (city => 'Str');
struct Person  => (name => 'Str', addr => 'Address');
sub get_city :sig((Person) -> Str) ($p) {
    return $p->addr()->city();
}
PERL

    is scalar @$errs, 0, 'two-level accessor chain resolves type';
};

# ── 1.2 Three-level accessor chain ──

subtest 'chain: three-level struct accessor' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct ZipCode => (code => 'Str');
struct Address => (zip => 'ZipCode');
struct Person  => (addr => 'Address');
sub get_zip :sig((Person) -> Str) ($p) {
    return $p->addr()->zip()->code();
}
PERL

    is scalar @$errs, 0, 'three-level accessor chain resolves';
};

# ── 1.3 Accessor chain type mismatch ──

subtest 'chain: accessor chain type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (value => 'Str');
struct Outer => (inner => 'Inner');
sub get_value :sig((Outer) -> Int) ($o) {
    return $o->inner()->value();
}
PERL

    ok scalar @$errs >= 1, 'accessor chain detects Str vs Int mismatch';
};

# ── 1.4 Derive then access ──

subtest 'chain: derive then accessor' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Config => (host => 'Str', port => 'Int');
sub with_port :sig((Config, Int) -> Str) ($c, $p) {
    my $c2 = Config::derive($c, port => $p);
    return $c2->host();
}
PERL

    is scalar @$errs, 0, 'derive preserves struct type for accessor';
};

# ════════════════════════════════════════════════
# Section 2: Map/Grep/Sort in Real Patterns
#   List processing idioms as Perl programmers write them
# ════════════════════════════════════════════════

# ── 2.1 map with struct field extraction ──

subtest 'map: struct field extraction' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Item => (name => 'Str', qty => 'Int');
sub item_names :sig((ArrayRef[Item]) -> ArrayRef[Str]) ($items) {
    [map { $_->name() } @$items];
}
PERL

    is scalar @$errs, 0, 'map extracts struct field into ArrayRef';
};

# ── 2.2 grep then map pipeline ──

subtest 'map: grep-then-map pipeline' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Record => (active => 'Bool', label => 'Str');
sub active_labels :sig((ArrayRef[Record]) -> ArrayRef[Str]) ($records) {
    my @active = grep { $_->active() } @$records;
    [map { $_->label() } @active];
}
PERL

    is scalar @$errs, 0, 'grep then map preserves struct element type';
};

# ── 2.3 sort with numeric comparator ──

subtest 'sort: numeric sort preserves type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub sorted_desc :sig((ArrayRef[Int]) -> ArrayRef[Int]) ($nums) {
    [sort { $b <=> $a } @$nums];
}
PERL

    is scalar @$errs, 0, 'sort with custom comparator preserves type';
};

# ── 2.4 map producing different type ──

subtest 'map: type transformation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub lengths :sig((ArrayRef[Str]) -> ArrayRef[Num]) ($strs) {
    [map { length($_) } @$strs];
}
PERL

    is scalar @$errs, 0, 'map with builtin transforms Str to Int/Num';
};

# ── 2.5 map type mismatch ──

subtest 'map: type mismatch in result' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub bad_map :sig((ArrayRef[Int]) -> ArrayRef[Str]) ($nums) {
    [map { $_ * 2 } @$nums];
}
PERL

    ok scalar @$errs >= 1, 'map returning Num assigned to ArrayRef[Str]';
};

# ════════════════════════════════════════════════
# Section 3: Declare Pattern
#   External function signatures via declare
# ════════════════════════════════════════════════

# ── 3.1 Simple declare usage ──

subtest 'declare: simple function declaration' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare parse_int => '(Str) -> Int';
sub test :sig(() -> Void) () {
    my $n :sig(Int) = parse_int("42");
}
PERL

    is scalar @$errs, 0, 'declare function returns correct type';
};

# ── 3.2 Declare with wrong arg type ──

subtest 'declare: argument type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare parse_int => '(Str) -> Int';
sub test :sig(() -> Void) () {
    parse_int(42);
}
PERL

    ok scalar @$errs >= 1, 'Int passed where Str expected in declared function';
};

# ── 3.3 Declare generic function ──

subtest 'declare: generic function instantiation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare identity => '<T>(T) -> T';
sub test :sig(() -> Void) () {
    my $n :sig(Int) = identity(42);
    my $s :sig(Str) = identity("hello");
}
PERL

    is scalar @$errs, 0, 'generic declared function instantiates correctly';
};

# ── 3.4 Declare with callback parameter ──

subtest 'declare: callback parameter type propagation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare map_array => '<A, B>(ArrayRef[A], (A) -> B) -> ArrayRef[B]';
sub test :sig(() -> Void) () {
    my $result :sig(ArrayRef[Str]) = map_array([1, 2, 3], sub ($n) { "item" });
}
PERL

    is scalar @$errs, 0, 'callback param type propagated from generic declare';
};

# ── 3.5 Declare arity check ──

subtest 'declare: arity mismatch' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
declare add => '(Int, Int) -> Int';
sub test :sig(() -> Void) () {
    add(1);
}
PERL

    ok scalar @$errs >= 1, 'declared function arity checked at call site';
};

# ════════════════════════════════════════════════
# Section 4: Effect and Handler Interactions
#   Multi-effect, handler resolution, effect-clean paths
# ════════════════════════════════════════════════

# ── 4.1 Pure function calling pure function ──

subtest 'effects: pure calling pure is OK' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
sub helper :sig((Int) -> Int) ($n) { $n + 1 }
sub main :sig((Int) -> Int) ($n) {
    helper($n);
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @$errs;
    is scalar @eff, 0, 'pure calling pure produces no effect error';
};

# ── 4.2 Effect function calling pure function ──

subtest 'effects: effectful calling pure is OK' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
effect Logger => +{ log => '(Str) -> Void' };
sub helper :sig((Int) -> Int) ($n) { $n + 1 }
sub main :sig((Int) -> Int ! Logger) ($n) {
    Logger::log("calling helper");
    helper($n);
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @$errs;
    is scalar @eff, 0, 'effectful caller can call pure callee';
};

# ── 4.3 Missing one of multiple effects ──

subtest 'effects: missing one effect from set' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
effect Logger  => +{ log  => '(Str) -> Void' };
effect Counter => +{ tick => '() -> Int' };
sub tick_and_log :sig(() -> Void ! Logger, Counter) () {
    Logger::log("tick");
    Counter::tick();
}
sub main :sig(() -> Void ! Logger) () {
    tick_and_log();
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @$errs;
    TODO: {
        local $TODO = 'effect subset checking does not yet detect missing individual effects';
        ok scalar @eff >= 1, 'missing Counter effect detected';
    }
};

# ── 4.4 Unannotated callee is gradual-pure ──

subtest 'effects: unannotated callee treated as pure' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
sub helper ($x) { $x + 1 }
sub main :sig((Int) -> Int) ($n) {
    helper($n);
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @$errs;
    is scalar @eff, 0, 'unannotated callee is gradual-pure';
};

# ════════════════════════════════════════════════
# Section 5: Subtype Interactions in Practice
#   Real-world patterns that exercise subtype checking
# ════════════════════════════════════════════════

# ── 5.1 Numeric tower in arithmetic ──

subtest 'subtype: Int + Int assignable to Num' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :sig((Int, Int) -> Num) ($a, $b) {
    $a + $b;
}
PERL

    is scalar @$errs, 0, 'Int arithmetic result <: Num';
};

# ── 5.2 Bool in numeric context ──

subtest 'subtype: Bool used as Int' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub count_true :sig((ArrayRef[Bool]) -> Int) ($flags) {
    my $count :sig(Int) = 0;
    for my $f (@$flags) {
        $count = $count + $f;
    }
    return $count;
}
PERL

    is scalar @$errs, 0, 'Bool used in Int arithmetic';
};

# ── 5.3 ArrayRef covariance in function argument ──

subtest 'subtype: ArrayRef[Bool] passed as ArrayRef[Int]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub sum :sig((ArrayRef[Int]) -> Int) ($nums) { 0 }
sub test :sig(() -> Void) () {
    my $flags :sig(ArrayRef[Bool]) = [1, 0, 1];
    my $s :sig(Int) = sum($flags);
}
PERL

    is scalar @$errs, 0, 'ArrayRef[Bool] <: ArrayRef[Int] via covariance';
};

# ── 5.4 Non-subtype rejected ──

subtest 'subtype: Str not subtype of Int' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_int :sig((Int) -> Void) ($n) { }
sub test :sig(() -> Void) () {
    takes_int("hello");
}
PERL

    ok scalar @$errs >= 1, 'Str not assignable to Int';
};

# ── 5.5 Any as universal supertype ──

subtest 'subtype: anything assignable to Any' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_any :sig((Any) -> Void) ($x) { }
sub test :sig(() -> Void) () {
    takes_any(42);
    takes_any("hello");
    takes_any([1, 2, 3]);
}
PERL

    is scalar @$errs, 0, 'all types <: Any';
};

# ════════════════════════════════════════════════
# Section 6: Newtype Patterns
#   Nominal type safety, coerce, construct
# ════════════════════════════════════════════════

# ── 6.1 Newtype prevents accidental mixing ──

subtest 'newtype: prevents mixing semantically different types' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
newtype Miles      => 'Int';
newtype Kilometers => 'Int';
sub to_km :sig((Miles) -> Kilometers) ($m) {
    Kilometers(Miles::coerce($m) * 1609 / 1000);
}
PERL

    is scalar @$errs, 0, 'newtype coerce extracts inner value';
};

# ── 6.2 Newtype is not its inner type ──

subtest 'newtype: not assignable to inner type directly' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
newtype UserId => 'Int';
sub takes_int :sig((Int) -> Void) ($n) { }
sub test :sig(() -> Void) () {
    my $id = UserId(42);
    takes_int($id);
}
PERL

    ok scalar @$errs >= 1, 'UserId not directly assignable to Int';
};

# ── 6.3 Newtype construction ──

subtest 'newtype: construction type-checked' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
newtype Email => 'Str';
sub test :sig(() -> Void) () {
    my $e = Email("user@example.com");
}
PERL

    is scalar @$errs, 0, 'newtype construction with valid inner type';
};

# ════════════════════════════════════════════════
# Section 7: Record and Hash Patterns
#   Structural typing, hash literal inference
# ════════════════════════════════════════════════

# ── 7.1 Hash literal matches Record via return ──

subtest 'record: hash literal as return value' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub config :sig(() -> Record[host => Str, port => Int]) () {
    +{ host => "localhost", port => 8080 };
}
PERL

    is scalar @$errs, 0, 'hash literal matches Record return type';
};

# ── 7.2 Hash literal field type mismatch ──

subtest 'record: hash literal field mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub config :sig(() -> Record[host => Str, port => Int]) () {
    +{ host => "localhost", port => "bad" };
}
PERL

    TODO: {
        local $TODO = 'Record return type field-level checking not yet implemented';
        ok scalar @$errs >= 1, 'string in Int field of Record detected';
    }
};

# ════════════════════════════════════════════════
# Section 8: Complex Generic Instantiation
#   Multi-step binding, nested generics, constraints
# ════════════════════════════════════════════════

# ── 8.1 Generic function with two vars bound from args ──

subtest 'generic: two vars bound independently' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare combine => '<A, B>(A, B) -> ArrayRef[A | B]';
sub test :sig(() -> Void) () {
    my $r :sig(ArrayRef[Int | Str]) = combine(42, "hello");
}
PERL

    is scalar @$errs, 0, 'two generic vars bound from different arg types';
};

# ── 8.2 Generic struct with multiple type params ──

subtest 'generic: struct with multiple type params' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct 'Entry[K, V]' => (key => K, val => V);
sub test :sig(() -> Void) () {
    my $e = Entry(key => "name", val => 42);
    my $k :sig(Str) = $e->key();
    my $v :sig(Int) = $e->val();
}
PERL

    is scalar @$errs, 0, 'multi-param generic struct fields resolve';
};

# ── 8.3 Nested generic container ──

subtest 'generic: nested ArrayRef generic' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare flatten => '<T>(ArrayRef[ArrayRef[T]]) -> ArrayRef[T]';
sub test :sig(() -> Void) () {
    my $nested :sig(ArrayRef[ArrayRef[Int]]) = [[1, 2], [3]];
    my $flat :sig(ArrayRef[Int]) = flatten($nested);
}
PERL

    is scalar @$errs, 0, 'nested generic ArrayRef resolves T=Int';
};

# ── 8.4 Generic return type from callback ──

subtest 'generic: return type inferred from callback' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare map_list => '<A, B>(ArrayRef[A], (A) -> B) -> ArrayRef[B]';
sub test :sig(() -> Void) () {
    my $nums :sig(ArrayRef[Int]) = [1, 2, 3];
    my $strs :sig(ArrayRef[Str]) = map_list($nums, sub ($n) { "num" });
}
PERL

    is scalar @$errs, 0, 'B resolved from callback return type';
};

# ── 8.5 Generic return type mismatch ──

subtest 'generic: return type mismatch after instantiation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare first => '<T>(ArrayRef[T]) -> T';
sub test :sig(() -> Void) () {
    my $nums :sig(ArrayRef[Int]) = [1, 2, 3];
    my $s :sig(Str) = first($nums);
}
PERL

    ok scalar @$errs >= 1, 'first(ArrayRef[Int]) returns Int, not Str';
};

# ════════════════════════════════════════════════
# Section 9: Narrowing Accessor Chains
#   defined($obj->field) narrowing patterns
# ════════════════════════════════════════════════

# ── 9.1 defined accessor narrows optional field ──

subtest 'accessor: defined narrows optional field' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Widget => (label => 'Str', optional(tooltip => 'Str'));
sub get_tooltip :sig((Widget) -> Str) ($w) {
    return "none" unless defined($w->tooltip());
    return $w->tooltip();
}
PERL

    is scalar @$errs, 0, 'defined accessor narrows optional to concrete';
};

# ── 9.2 Multiple optional fields narrowed ──

subtest 'accessor: multiple optional fields narrowed' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Form => (
    name  => 'Str',
    optional(email => 'Str'),
    optional(phone => 'Str'),
);
sub has_contact :sig((Form) -> Str) ($f) {
    return "email" if defined($f->email());
    return "phone" if defined($f->phone());
    return "none";
}
PERL

    is scalar @$errs, 0, 'multiple optional field guards';
};

# ════════════════════════════════════════════════
# Section 10: Bidirectional Inference Patterns
#   Expected type guides inference
# ════════════════════════════════════════════════

# ── 10.1 Expected type guides array literal ──

subtest 'bidir: expected type guides array literal' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $xs :sig(ArrayRef[Int]) = [1, 2, 3];
}
PERL

    is scalar @$errs, 0, 'array literal matches expected ArrayRef[Int]';
};

# ── 10.2 Expected type catches array element mismatch ──

subtest 'bidir: expected type catches element mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $xs :sig(ArrayRef[Int]) = [1, "bad", 3];
}
PERL

    ok scalar @$errs >= 1, 'string element in ArrayRef[Int] detected';
};

# ── 10.3 Return type guides expression ──

subtest 'bidir: return type guides hash literal' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub make_config :sig(() -> Record[name => Str, count => Int]) () {
    +{ name => "test", count => 5 };
}
PERL

    is scalar @$errs, 0, 'hash literal matches Record return type';
};

# ── 10.4 Ternary with expected type ──

subtest 'bidir: ternary arms guided by expected' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Bool) -> Int) ($flag) {
    $flag ? 1 : 0;
}
PERL

    is scalar @$errs, 0, 'ternary with Int literals as implicit return';
};

# ════════════════════════════════════════════════
# Section 11: Struct Construction Edge Cases
#   Various construction patterns and field checks
# ════════════════════════════════════════════════

# ── 11.1 Struct with all required fields ──

subtest 'struct-ctor: all required fields provided' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Point => (x => 'Int', y => 'Int');
sub test :sig(() -> Void) () {
    my $p = Point(x => 1, y => 2);
}
PERL

    is scalar @$errs, 0, 'all required fields provided';
};

# ── 11.2 Struct missing required field ──

subtest 'struct-ctor: missing required field' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
struct Point => (x => 'Int', y => 'Int');
sub test :sig(() -> Void) () {
    my $p = Point(x => 1);
}
PERL

    my @struct_errs = grep { $_->{kind} =~ /TypeMismatch|Missing|Arity/ } @$errs;
    ok scalar @struct_errs >= 1, 'missing required field detected';
};

# ── 11.3 Struct with unknown field ──

subtest 'struct-ctor: unknown field rejected' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
struct Point => (x => 'Int', y => 'Int');
sub test :sig(() -> Void) () {
    my $p = Point(x => 1, y => 2, z => 3);
}
PERL

    my @struct_errs = grep { $_->{kind} =~ /TypeMismatch|Unknown|Field/ } @$errs;
    ok scalar @struct_errs >= 1, 'unknown field z rejected';
};

# ── 11.4 Struct with optional field omitted ──

subtest 'struct-ctor: optional field can be omitted' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Person => (name => 'Str', optional(email => 'Str'));
sub test :sig(() -> Void) () {
    my $p = Person(name => "Taro");
}
PERL

    is scalar @$errs, 0, 'optional field can be omitted in constructor';
};

# ── 11.5 Struct optional field provided ──

subtest 'struct-ctor: optional field provided' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Person => (name => 'Str', optional(email => 'Str'));
sub test :sig(() -> Void) () {
    my $p = Person(name => "Taro", email => "t@example.com");
}
PERL

    is scalar @$errs, 0, 'optional field accepted when provided';
};

# ════════════════════════════════════════════════
# Section 12: Edge Cases in Annotation Parsing
#   Complex type expressions in :sig()
# ════════════════════════════════════════════════

# ── 12.1 Nested union in param ──

subtest 'annotation: nested union in parameter' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Int | Str | Bool) -> Str) ($x) {
    return "ok";
}
PERL

    is scalar @$errs, 0, 'three-member union parsed correctly';
};

# ── 12.2 Function type with multiple params ──

subtest 'annotation: multi-param function type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub apply :sig(((Int, Str) -> Bool, Int, Str) -> Bool) ($f, $n, $s) {
    $f->($n, $s);
}
PERL

    is scalar @$errs, 0, 'multi-param function type annotation';
};

# ── 12.3 Annotation with effects ──

subtest 'annotation: function with effect annotation' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
effect Logger => +{ log => '(Str) -> Void' };
sub test :sig((Str) -> Void ! Logger) ($msg) {
    Logger::log($msg);
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @$errs;
    is scalar @eff, 0, 'effect annotation parsed and checked';
};

# ── 12.4 Annotation with generics and effects ──

subtest 'annotation: generics with effects' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
effect Logger => +{ log => '(Str) -> Void' };
sub traced :sig(<T>((T) -> T, T) -> T ! Logger) ($f, $x) {
    Logger::log("calling");
    $f->($x);
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @$errs;
    is scalar @eff, 0, 'generic + effect annotation works';
};

# ════════════════════════════════════════════════
# Section 13: Variable Lifecycle
#   Declaration, initialization, re-assignment, scope
# ════════════════════════════════════════════════

# ── 13.1 Variable used before init should not crash ──

subtest 'lifecycle: uninitialized variable graceful' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x :sig(Int);
    $x = 42;
}
PERL

    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @$errs;
    is scalar @type_errs, 0, 'uninitialized then assigned is OK';
};

# ── 13.2 Re-assignment preserves annotation ──

subtest 'lifecycle: re-assignment checked against annotation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x :sig(Int) = 1;
    $x = 2;
    $x = 3;
}
PERL

    is scalar @$errs, 0, 'multiple valid re-assignments';
};

# ── 13.3 Wrong re-assignment detected ──

subtest 'lifecycle: wrong re-assignment detected' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x :sig(Int) = 1;
    $x = "bad";
}
PERL

    ok scalar @$errs >= 1, 'Str re-assignment to Int var detected';
};

# ── 13.4 Param used in various expressions ──

subtest 'lifecycle: param in compound expressions' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub compute :sig((Int, Int) -> Int) ($a, $b) {
    my $sum :sig(Int) = $a + $b;
    my $diff :sig(Int) = $a - $b;
    return $sum;
}
PERL

    is scalar @$errs, 0, 'params used in multiple expressions';
};

# ════════════════════════════════════════════════
# Section 14: @typist-ignore Suppression
#   Pragma-like error suppression
# ════════════════════════════════════════════════

# ── 14.1 @typist-ignore suppresses TypeMismatch ──

subtest 'ignore: suppresses TypeMismatch on next line' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    # @typist-ignore
    my $x :sig(Int) = "hello";
}
PERL

    is scalar @$errs, 0, '@typist-ignore suppresses type error';
};

# ── 14.2 @typist-ignore only suppresses targeted line ──

subtest 'ignore: does not suppress other lines' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    # @typist-ignore
    my $x :sig(Int) = "hello";
    my $y :sig(Int) = "world";
}
PERL

    ok scalar @$errs >= 1, '@typist-ignore only affects the next line';
};

done_testing;
