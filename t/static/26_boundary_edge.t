use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::Analyze qw(analyze type_errors arity_errors all_errors diags_of_kind);

# ════════════════════════════════════════════════
# Section 1: Subtype Boundary Tests
#   Exact boundaries of the type lattice
# ════════════════════════════════════════════════

# ── 1.1 Bool is the bottom of numeric tower ──

subtest 'lattice: Bool <: Int <: Double <: Num <: Any' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $b :sig(Bool) = 1;
    my $i :sig(Int) = $b;
    my $d :sig(Double) = $i;
    my $n :sig(Num) = $d;
    my $a :sig(Any) = $n;
}
PERL

    is scalar @$errs, 0, 'full numeric tower assignment chain works';
};

# ── 1.2 Str not in numeric tower ──

subtest 'lattice: Str is not Int' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $s :sig(Str) = "hello";
    my $n :sig(Int) = $s;
}
PERL

    ok scalar @$errs >= 1, 'Str cannot be assigned to Int';
};

# ── 1.3 Int is not Str ──

subtest 'lattice: Int is not Str' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $i :sig(Int) = 42;
    my $s :sig(Str) = $i;
}
PERL

    ok scalar @$errs >= 1, 'Int cannot be assigned to Str';
};

# ── 1.4 Undef is its own type ──

subtest 'lattice: Undef not assignable to Int' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $u :sig(Undef) = undef;
    my $n :sig(Int) = $u;
}
PERL

    ok scalar @$errs >= 1, 'Undef cannot be assigned to Int';
};

# ── 1.5 Maybe[T] includes both T and Undef ──

subtest 'lattice: Maybe[Int] accepts both Int and undef' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $a :sig(Maybe[Int]) = 42;
    my $b :sig(Maybe[Int]) = undef;
}
PERL

    is scalar @$errs, 0, 'Maybe[Int] accepts both Int and undef';
};

# ── 1.6 Void function cannot return non-void ──

subtest 'lattice: Void function rejects explicit non-void return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    return 42;
}
PERL

    ok scalar @$errs >= 1, 'Void function cannot return Int';
};

# ════════════════════════════════════════════════
# Section 2: Container Variance
#   Covariance of parameterized types
# ════════════════════════════════════════════════

# ── 2.1 ArrayRef[Int] <: ArrayRef[Num] ──

subtest 'variance: ArrayRef[Int] <: ArrayRef[Num]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_nums :sig((ArrayRef[Num]) -> Void) ($ns) { }
sub test :sig(() -> Void) () {
    my $ints :sig(ArrayRef[Int]) = [1, 2];
    takes_nums($ints);
}
PERL

    is scalar @$errs, 0, 'ArrayRef[Int] <: ArrayRef[Num] via covariance';
};

# ── 2.2 ArrayRef[Str] not <: ArrayRef[Int] ──

subtest 'variance: ArrayRef[Str] not <: ArrayRef[Int]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_ints :sig((ArrayRef[Int]) -> Void) ($ns) { }
sub test :sig(() -> Void) () {
    my $strs :sig(ArrayRef[Str]) = ["a"];
    takes_ints($strs);
}
PERL

    ok scalar @$errs >= 1, 'ArrayRef[Str] not <: ArrayRef[Int]';
};

# ── 2.3 Nested covariance: ArrayRef[ArrayRef[Bool]] <: ArrayRef[ArrayRef[Int]] ──

subtest 'variance: nested covariance' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_nested :sig((ArrayRef[ArrayRef[Int]]) -> Void) ($m) { }
sub test :sig(() -> Void) () {
    my $bools :sig(ArrayRef[ArrayRef[Bool]]) = [[1, 0]];
    takes_nested($bools);
}
PERL

    is scalar @$errs, 0, 'nested ArrayRef covariance';
};

# ════════════════════════════════════════════════
# Section 3: Union Type Semantics
#   Union creation, narrowing, assignment
# ════════════════════════════════════════════════

# ── 3.1 Union member accepted ──

subtest 'union: Int member accepted in Int | Str' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_union :sig((Int | Str) -> Void) ($x) { }
sub test :sig(() -> Void) () {
    takes_union(42);
    takes_union("hello");
}
PERL

    is scalar @$errs, 0, 'both members of union accepted';
};

# ── 3.2 Union non-member rejected ──

subtest 'union: Bool[] not in Int | Str' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_union :sig((Int | Str) -> Void) ($x) { }
sub test :sig(() -> Void) () {
    my $arr :sig(ArrayRef[Int]) = [1];
    takes_union($arr);
}
PERL

    ok scalar @$errs >= 1, 'ArrayRef not in Int | Str union';
};

# ── 3.3 Union in return type ──

subtest 'union: function returns union member' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub parse :sig((Str) -> Int | Str) ($s) {
    if ($s eq "42") {
        return 42;
    }
    return $s;
}
PERL

    is scalar @$errs, 0, 'function returning different union members';
};

# ── 3.4 Union narrowing via isa ──

subtest 'union: isa narrows union' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Cat => (sound => 'Str');
struct Dog => (sound => 'Str');
sub identify :sig((Cat | Dog) -> Str) ($pet) {
    if ($pet isa Cat) {
        return "cat: " . $pet->sound();
    }
    return "dog";
}
PERL

    is scalar @$errs, 0, 'isa narrows union member';
};

# ════════════════════════════════════════════════
# Section 4: Function Type Semantics
#   Higher-order function type assignments
# ════════════════════════════════════════════════

# ── 4.1 Function value assigned to typed var ──

subtest 'func: anonymous sub to typed var' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $f :sig((Int) -> Str) = sub ($n) { "x" };
}
PERL

    is scalar @$errs, 0, 'anonymous sub assigned to function type var';
};

# ── 4.2 Function value passed as argument ──

subtest 'func: anonymous sub as argument' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub apply :sig(((Int) -> Str, Int) -> Str) ($f, $n) {
    $f->($n);
}
sub test :sig(() -> Void) () {
    my $r :sig(Str) = apply(sub ($n) { "x" }, 42);
}
PERL

    is scalar @$errs, 0, 'anonymous sub as function argument';
};

# ── 4.3 Curried function ──

subtest 'func: curried function return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :sig((Int) -> (Int) -> Int) ($a) {
    sub ($b) { $a + $b };
}
sub test :sig(() -> Void) () {
    my $add5 :sig((Int) -> Int) = add(5);
}
PERL

    is scalar @$errs, 0, 'curried function type-checks';
};

# ════════════════════════════════════════════════
# Section 5: Inference Precision Tests
#   Verify inference produces correct types
# ════════════════════════════════════════════════

# ── 5.1 Arithmetic type inference ──

subtest 'infer: Int + Int → Num (arithmetic widens)' => sub {
    my $r = analyze(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x = 1 + 2;
}
PERL

    my @il = grep { $_->{name} eq '$x' } @{$r->{infer_log}};
    ok @il && $il[0]{type} =~ /Int|Num/, 'arithmetic infers numeric type';
};

# ── 5.2 String concat inference ──

subtest 'infer: Str . Str → Str' => sub {
    my $r = analyze(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x = "hello" . " " . "world";
}
PERL

    my @il = grep { $_->{name} eq '$x' } @{$r->{infer_log}};
    ok @il && $il[0]{type} eq 'Str', 'string concat infers Str';
};

# ── 5.3 Comparison → Bool ──

subtest 'infer: comparison → Bool' => sub {
    my $r = analyze(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x = 1 > 0;
}
PERL

    my @il = grep { $_->{name} eq '$x' } @{$r->{infer_log}};
    ok @il && $il[0]{type} eq 'Bool', 'comparison infers Bool';
};

# ── 5.4 Ternary LUB ──

subtest 'infer: ternary with same type → that type' => sub {
    my $r = analyze(<<'PERL');
use v5.40;
sub test :sig((Bool) -> Void) ($flag) {
    my $x = $flag ? "yes" : "no";
}
PERL

    my @il = grep { $_->{name} eq '$x' } @{$r->{infer_log}};
    ok @il && $il[0]{type} eq 'Str', 'ternary with same-type arms → Str';
};

# ── 5.5 Defined-or inference ──

subtest 'infer: defined-or produces LUB' => sub {
    my $r = analyze(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $n :sig(Maybe[Int]) = 42;
    my $x = $n // 0;
}
PERL

    my @il = grep { $_->{name} eq '$x' } @{$r->{infer_log}};
    ok @il, 'defined-or produces inferred type';
};

# ── 5.6 Function call inference ──

subtest 'infer: function call returns declared type' => sub {
    my $r = analyze(<<'PERL');
use v5.40;
sub get_num :sig(() -> Int) () { 42 }
sub test :sig(() -> Void) () {
    my $x = get_num();
}
PERL

    my @il = grep { $_->{name} eq '$x' } @{$r->{infer_log}};
    ok @il && $il[0]{type} eq 'Int', 'function call infers return type';
};

# ── 5.7 Regex match → Bool ──

subtest 'infer: regex match → Bool' => sub {
    my $r = analyze(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $s :sig(Str) = "hello";
    my $x = $s =~ /pattern/;
}
PERL

    my @il = grep { $_->{name} eq '$x' } @{$r->{infer_log}};
    ok @il && $il[0]{type} eq 'Bool', '=~ infers Bool';
};

# ════════════════════════════════════════════════
# Section 6: Diagnostic Precision
#   Verify diagnostics report correct locations/types
# ════════════════════════════════════════════════

# ── 6.1 TypeMismatch has col ──

subtest 'diag-precision: TypeMismatch includes col' => sub {
    my $r = analyze(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x :sig(Int) = "hello";
}
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } @{$r->{diagnostics}};
    ok @errs >= 1, 'error found';
    ok defined $errs[0]{col}, 'col present in diagnostic' if @errs;
};

# ── 6.2 Multiple errors in same function ──

subtest 'diag-precision: multiple errors in same function' => sub {
    my $r = analyze(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x :sig(Int) = "hello";
    my $y :sig(Str) = 42;
}
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } @{$r->{diagnostics}};
    ok @errs >= 2, 'multiple errors in same function detected';
};

# ── 6.3 Error in correct function ──

subtest 'diag-precision: error attributed to correct function' => sub {
    my $r = analyze(<<'PERL');
use v5.40;
sub good :sig(() -> Void) () {
    my $x :sig(Int) = 42;
}
sub bad :sig(() -> Int) () {
    return "oops";
}
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } @{$r->{diagnostics}};
    ok @errs >= 1, 'error found';
    like $errs[0]{message}, qr/bad/, 'error mentions bad function' if @errs;
};

# ════════════════════════════════════════════════
# Section 7: Gradual Typing Interactions
#   Boundary between annotated and unannotated code
# ════════════════════════════════════════════════

# ── 7.1 Unannotated function does not cause errors ──

subtest 'gradual: unannotated function causes no errors' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub helper ($x) { $x + 1 }
PERL

    is scalar @$errs, 0, 'unannotated function is gradual';
};

# ── 7.2 Annotated function calling unannotated ──

subtest 'gradual: annotated uses unannotated result' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub helper ($x) { $x }
sub typed :sig(() -> Void) () {
    my $r :sig(Int) = helper(42);
}
PERL

    is scalar @$errs, 0, 'unannotated returns Any, assignable to Int';
};

# ── 7.3 Mixed annotation partial ──

subtest 'gradual: partially annotated function' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
sub partial :sig((Int) -> Any) ($n) {
    return $n + 1;
}
PERL

    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @$errs;
    is scalar @type_errs, 0, 'Any return type skips check';
};

# ── 7.4 Unannotated params are Any ──

subtest 'gradual: unannotated params treated as Any' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test ($x, $y) {
    my $sum = $x + $y;
}
PERL

    is scalar @$errs, 0, 'unannotated params are permissive';
};

# ════════════════════════════════════════════════
# Section 8: Struct Accessor Patterns
#   Various accessor usage patterns
# ════════════════════════════════════════════════

# ── 8.1 Multiple field access ──

subtest 'accessor: multiple field access' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Point => (x => 'Int', y => 'Int');
sub manhattan :sig((Point, Point) -> Int) ($a, $b) {
    my $dx :sig(Int) = $a->x() - $b->x();
    my $dy :sig(Int) = $a->y() - $b->y();
    return $dx + $dy;
}
PERL

    is scalar @$errs, 0, 'multiple field accessors on same struct';
};

# ── 8.2 Struct as argument and return ──

subtest 'accessor: struct arg and return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Vector => (x => 'Int', y => 'Int');
sub negate :sig((Vector) -> Vector) ($v) {
    Vector(x => 0 - $v->x(), y => 0 - $v->y());
}
PERL

    is scalar @$errs, 0, 'struct as both arg and return';
};

# ── 8.3 Struct passed to another function ──

subtest 'accessor: struct passed to typed function' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Name => (first => 'Str', last => 'Str');
sub format_name :sig((Name) -> Str) ($n) {
    $n->first() . " " . $n->last();
}
sub greet :sig((Name) -> Str) ($n) {
    "Hello, " . format_name($n);
}
PERL

    is scalar @$errs, 0, 'struct passed between typed functions';
};

# ════════════════════════════════════════════════
# Section 9: Complex Real-World Patterns
#   Patterns from actual Perl codebases
# ════════════════════════════════════════════════

# ── 9.1 Config builder pattern ──

subtest 'real: config builder' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct DBConfig => (host => 'Str', port => 'Int', name => 'Str');
sub default_config :sig(() -> DBConfig) () {
    DBConfig(host => "localhost", port => 5432, name => "mydb");
}
sub with_host :sig((DBConfig, Str) -> DBConfig) ($c, $h) {
    DBConfig::derive($c, host => $h);
}
PERL

    is scalar @$errs, 0, 'config builder pattern';
};

# ── 9.2 Repository pattern ──

subtest 'real: repository-like pattern' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct User => (id => 'Int', name => 'Str');
declare find_user => '(Int) -> Maybe[User]';
sub get_name :sig((Int) -> Str) ($id) {
    my $user = find_user($id);
    return "unknown" unless defined $user;
    return $user->name();
}
PERL

    is scalar @$errs, 0, 'repository pattern with Maybe + narrowing';
};

# ── 9.3 Validation pipeline ──

subtest 'real: validation pipeline' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub validate_name :sig((Str) -> Bool) ($s) {
    my $len = length($s);
    $len > 0;
}
sub validate_age :sig((Int) -> Bool) ($n) {
    $n >= 0;
}
sub is_valid :sig((Str, Int) -> Bool) ($name, $age) {
    my $name_ok :sig(Bool) = validate_name($name);
    my $age_ok :sig(Bool) = validate_age($age);
    return 0 unless $name_ok;
    return 0 unless $age_ok;
    return 1;
}
PERL

    is scalar @$errs, 0, 'validation pipeline with Bool returns';
};

# ── 9.4 State machine pattern ──

subtest 'real: state machine with ADT' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype State => Idle => '()', Running => '(Int)', Done => '(Str)';
sub transition :sig((State) -> State) ($s) {
    match $s,
        Idle    => sub { Running(0) },
        Running => sub ($n) { $n >= 10 ? Done("complete") : Running($n + 1) },
        Done    => sub ($msg) { Done($msg) };
}
PERL

    is scalar @$errs, 0, 'state machine with ADT transitions';
};

# ── 9.5 Error handling pattern ──

subtest 'real: result-based error handling' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype 'Result[T]' => Ok => '(T)', Err => '(Str)';
sub parse_int :sig((Str) -> Result[Int]) ($s) {
    if ($s =~ /^\d+$/) {
        return Ok(42);
    }
    return Err("not a number");
}
PERL

    is scalar @$errs, 0, 'Result type for error handling';
};

# ── 9.6 Event handler pattern ──

subtest 'real: event handler with effects' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
effect Logger => +{ log => '(Str) -> Void' };
struct Event => (name => 'Str', data => 'Str');
sub handle_event :sig((Event) -> Void ! Logger) ($e) {
    Logger::log("handling " . $e->name());
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @$errs;
    is scalar @eff, 0, 'event handler with Logger effect';
};

done_testing;
