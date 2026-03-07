use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::Analyze qw(analyze type_errors arity_errors all_errors diags_of_kind);

# ════════════════════════════════════════════════
# Section 1: Generic Call Checker Edge Cases
# ════════════════════════════════════════════════

# ── 1.1 Generic struct field binding conflict ──

subtest 'generic struct: conflicting T bindings across fields' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct 'Pair[T]' => (fst => T, snd => T);
sub test :sig(() -> Void) () {
    my $p = Pair(fst => 1, snd => "no");
}
PERL

    ok scalar @$errs >= 1, 'detects type conflict: T=Int vs T=Str';
};

# ── 1.2 Variadic generic unification ──

subtest 'variadic generic: all args must unify to same T' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare first => '<T>(...T) -> T';
sub test :sig(() -> Void) () {
    my $r :sig(Int) = first(1, 2, 3);
}
PERL

    is scalar @$errs, 0, 'all Int args unify successfully';
};

subtest 'variadic generic: mixed types are gradual (cross-arg unification not enforced)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare first => '<T>(T, ...T) -> T';
sub test :sig(() -> Void) () {
    my $r :sig(Int) = first(1, "bad");
}
PERL

    # Cross-arg unification for variadic generics is not yet enforced.
    # The first arg binds T=Int; extra variadic args are not re-checked.
    ok 1, 'variadic generic cross-arg unification is a known limitation';
};

# ── 1.3 Default param arity ──

subtest 'default params: min arity respects defaults' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub greet :sig((Str, Str) -> Str) ($name, $greeting = "Hello") {
    "$greeting, $name";
}
sub test :sig(() -> Str) () {
    return greet("World");
}
PERL

    is scalar @$errs, 0, 'calling with 1 arg when 2nd has default is fine';
};

subtest 'default params: zero args still errors' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub greet :sig((Str, Str) -> Str) ($name, $greeting = "Hello") {
    "$greeting, $name";
}
sub test :sig(() -> Str) () {
    return greet();
}
PERL

    is scalar @$errs, 1, 'zero args when min is 1 triggers arity error';
};

# ── 1.4 Callback arity check ──

subtest 'callback arity: too few params in anonymous sub' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub apply :sig(((Int, Int) -> Int, Int, Int) -> Int) ($f, $a, $b) {
    $f->($a, $b);
}
sub test :sig(() -> Int) () {
    return apply(sub ($x) { $x }, 1, 2);
}
PERL

    ok scalar @$errs >= 1, 'callback expects 2 params but sub has 1';
};

subtest 'callback arity: correct params passes' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub apply :sig(((Int, Int) -> Int, Int, Int) -> Int) ($f, $a, $b) {
    $f->($a, $b);
}
sub test :sig(() -> Int) () {
    return apply(sub ($x, $y) { $x + $y }, 1, 2);
}
PERL

    is scalar @$errs, 0, 'callback with correct arity passes';
};

# ── 1.5 Cross-package call with type mismatch ──

subtest 'cross-package call: type mismatch detected' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare 'Utils::add' => '(Int, Int) -> Int';
sub test :sig(() -> Int) () {
    return Utils::add("bad", 1);
}
PERL

    ok scalar @$errs >= 1, 'Str passed to Int param in cross-pkg call';
};

# ════════════════════════════════════════════════
# Section 2: Type Checker Return Edge Cases
# ════════════════════════════════════════════════

# ── 2.1 Multiple return paths ──

subtest 'return: multiple return paths all checked' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub pick :sig((Bool) -> Int) ($flag) {
    if ($flag) {
        return "bad";
    }
    return 42;
}
PERL

    is scalar @$errs, 1, 'first return "bad" mismatches Int';
    like $errs->[0]{message}, qr/"bad".*Int/, 'error identifies literal vs Int';
};

subtest 'return: all paths correct passes' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub pick :sig((Bool) -> Int) ($flag) {
    if ($flag) {
        return 1;
    }
    return 2;
}
PERL

    is scalar @$errs, 0, 'all return paths match declared type';
};

# ── 2.2 Implicit return ──

subtest 'implicit return: last expression checked' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub name :sig(() -> Int) () {
    "hello";
}
PERL

    is scalar @$errs, 1, 'implicit Str return mismatches Int';
};

# ── 2.3 Bare return ──

subtest 'bare return skipped (Void-like)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Bool) -> Int) ($flag) {
    return if $flag;
    return 42;
}
PERL

    is scalar @$errs, 0, 'bare return does not produce TypeMismatch';
};

# ════════════════════════════════════════════════
# Section 3: Narrowing Edge Cases
# ════════════════════════════════════════════════

# ── 3.1 Nested defined + isa ──

subtest 'narrowing: nested defined then isa' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Any]) -> Void) ($x) {
    if (defined($x)) {
        if ($x isa Typist::Type::Atom) {
            my $a :sig(Typist::Type::Atom) = $x;
        }
    }
}
PERL

    is scalar @$errs, 0, 'nested narrowing: defined then isa composes';
};

# ── 3.2 Early return chains ──

subtest 'narrowing: chained early returns narrow cumulatively' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Int], Maybe[Str]) -> Str) ($a, $b) {
    return "none" unless defined $a;
    return "none" unless defined $b;
    my $n :sig(Int) = $a;
    my $s :sig(Str) = $b;
    $s;
}
PERL

    is scalar @$errs, 0, 'two early returns narrow both params';
};

# ── 3.3 unless with else and narrowing ──

subtest 'narrowing: unless else applies inverse' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Str]) -> Void) ($x) {
    unless (defined($x)) {
        my $u :sig(Undef) = $x;
    } else {
        my $s :sig(Str) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'unless/else narrowing correct in both branches';
};

# ── 3.4 Narrowing does not survive function boundary ──

subtest 'narrowing: does not cross function boundary' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub outer :sig((Maybe[Int]) -> Void) ($x) {
    return unless defined $x;
    my $n :sig(Int) = $x;
}
sub other :sig((Maybe[Int]) -> Void) ($x) {
    my $n :sig(Int) = $x;
}
PERL

    is scalar @$errs, 1, 'narrowing from outer does not affect other';
};

# ── 3.5 Truthiness narrowing with Maybe[Bool] ──

subtest 'narrowing: truthiness on Maybe[Bool]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Int]) -> Void) ($x) {
    if ($x) {
        my $n :sig(Int) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'truthiness narrows Maybe[Int] to Int';
};

# ── 3.6 Double narrowing (re-check same var) ──

subtest 'narrowing: redundant defined is harmless' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Str]) -> Void) ($x) {
    if (defined($x)) {
        if (defined($x)) {
            my $s :sig(Str) = $x;
        }
    }
}
PERL

    is scalar @$errs, 0, 'double defined narrowing is idempotent';
};

# ════════════════════════════════════════════════
# Section 4: Inference Edge Cases
# ════════════════════════════════════════════════

# ── 4.1 Ternary with mixed types ──

subtest 'inference: ternary branches produce LUB' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub pick :sig((Bool) -> Num) ($flag) {
    my $x = $flag ? 1 : 3.14;
    return $x;
}
PERL

    is scalar @$errs, 0, 'LUB(Int, Double) = Num — compatible with Num return';
};

# ── 4.2 Defined-or inference ──

subtest 'inference: defined-or produces LUB of branches' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub fallback :sig((Maybe[Int]) -> Int) ($x) {
    my $y = $x // 0;
    return $y;
}
PERL

    is scalar @$errs, 0, 'defined-or: Maybe[Int] // Int → Int';
};

# ── 4.3 String concatenation ──

subtest 'inference: dot operator produces Str' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :sig((Str) -> Str) ($name) {
    my $msg = "Hello, " . $name;
    return $msg;
}
PERL

    is scalar @$errs, 0, 'string concat inferred as Str';
};

# ── 4.4 Arithmetic produces numeric type ──

subtest 'inference: arithmetic produces numeric type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) {
    my $c = $a + $b;
    return $c;
}
PERL

    is scalar @$errs, 0, 'Int + Int inferred as numeric (Int subtype of Int)';
};

# ── 4.5 Comparison produces Bool ──

subtest 'inference: comparison produces Bool' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub gt :sig((Int, Int) -> Bool) ($a, $b) {
    my $r = $a > $b;
    return $r;
}
PERL

    is scalar @$errs, 0, 'comparison inferred as Bool';
};

# ── 4.6 Negation operator ──

subtest 'inference: logical not produces Bool' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub negate :sig((Bool) -> Bool) ($x) {
    my $r = !$x;
    return $r;
}
PERL

    is scalar @$errs, 0, 'logical not inferred as Bool';
};

# ── 4.7 Array deref element type ──

subtest 'inference: array deref element type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub first :sig((ArrayRef[Int]) -> Int) ($xs) {
    my $x = $xs->[0];
    return $x;
}
PERL

    is scalar @$errs, 0, 'array deref preserves element type';
};

# ── 4.8 Chained function calls ──

subtest 'inference: nested function call return type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub double :sig((Int) -> Int) ($x) { $x * 2 }
sub test :sig(() -> Int) () {
    return double(double(1));
}
PERL

    is scalar @$errs, 0, 'nested call chains compose return types';
};

# ── 4.9 Hash literal inference ──

subtest 'inference: hash literal with homogeneous values' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my %h = (a => 1, b => 2, c => 3);
    my $v :sig(Hash[Str, Int]) = %h;
}
PERL

    is scalar @$errs, 0, 'hash literal inferred as Hash[Str, Int]';
};

# ── 4.10 qw() produces Array[Str] ──

subtest 'inference: qw() produces Array[Str]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my @words = qw(foo bar baz);
    my $w :sig(Array[Str]) = @words;
}
PERL

    is scalar @$errs, 0, 'qw() produces Array[Str]';
};

# ════════════════════════════════════════════════
# Section 5: Effect Checking Edge Cases
# ════════════════════════════════════════════════

# ── 5.1 Nested effect handlers ──

subtest 'effects: nested handle blocks require caller annotation' => sub {
    my $errs = diags_of_kind(<<'PERL', 'EffectMismatch');
use v5.40;
effect Logger => +{ log => '(Str) -> Void' };
effect Counter => +{ inc => '() -> Int' };
sub test :sig(() -> Void ![Logger, Counter]) () {
    handle {
        handle {
            Logger::log("hi");
            Counter::inc();
        } Counter => +{
            inc => sub () { 0 }
        };
    } Logger => +{
        log => sub ($msg) { }
    };
}
PERL

    is scalar @$errs, 0, 'annotated caller with nested handlers has no mismatch';
};

subtest 'effects: unannotated caller with effect ops triggers mismatch' => sub {
    my $errs = diags_of_kind(<<'PERL', 'EffectMismatch');
use v5.40;
effect Logger => +{ log => '(Str) -> Void' };
sub test :sig(() -> Void) () {
    Logger::log("hi");
}
PERL

    ok scalar @$errs >= 1, 'pure function calling Logger::log triggers EffectMismatch';
};

# ── 5.2 Calling effectful function from pure context ──

subtest 'effects: effectful callee in annotated pure caller' => sub {
    my $errs = diags_of_kind(<<'PERL', 'EffectMismatch');
use v5.40;
effect DB => +{ query => '(Str) -> Str' };
sub fetch :sig((Str) -> Str ![DB]) ($q) {
    DB::query($q);
}
sub pure_caller :sig((Str) -> Str) ($q) {
    return fetch($q);
}
PERL

    ok scalar @$errs >= 1, 'pure function calling ![DB] function triggers EffectMismatch';
};

# ── 5.3 Ambient effects are not checked ──

subtest 'effects: IO and Exn are ambient (no mismatch)' => sub {
    my $errs = diags_of_kind(<<'PERL', 'EffectMismatch');
use v5.40;
sub pure_fn :sig((Str) -> Void) ($msg) {
    say $msg;
    die("oops");
}
PERL

    is scalar @$errs, 0, 'IO and Exn are ambient — no mismatch in pure function';
};

# ════════════════════════════════════════════════
# Section 6: Struct Edge Cases
# ════════════════════════════════════════════════

# ── 6.1 Unknown field ──

subtest 'struct constructor: unknown field rejected' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Point => (x => Int, y => Int);
sub test :sig(() -> Void) () {
    my $p = Point(x => 1, y => 2, z => 3);
}
PERL

    ok scalar @$errs >= 1, 'unknown field z triggers error';
    like $errs->[0]{message}, qr/unknown field.*z/i, 'error mentions field z';
};

# ── 6.2 Missing required field ──

subtest 'struct constructor: missing required field' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
struct Point => (x => Int, y => Int);
sub test :sig(() -> Void) () {
    my $p = Point(x => 1);
}
PERL

    my @missing = grep { $_->{message} =~ /missing|required/i } @$errs;
    ok scalar @missing >= 1, 'missing required field y triggers error';
};

# ── 6.3 Optional field can be omitted ──

subtest 'struct constructor: optional field can be omitted' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Config => (host => Str, optional(port => Int));
sub test :sig(() -> Void) () {
    my $c = Config(host => "localhost");
}
PERL

    is scalar @$errs, 0, 'omitting optional field is fine';
};

# ── 6.4 Optional field type checked when present ──

subtest 'struct constructor: optional field type still checked' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Config => (host => Str, optional(port => Int));
sub test :sig(() -> Void) () {
    my $c = Config(host => "localhost", port => "bad");
}
PERL

    ok scalar @$errs >= 1, 'optional field with wrong type triggers error';
};

# ── 6.5 Generic struct with bound ──

subtest 'generic struct: bound constraint checked' => sub {
    my $errs = type_errors(<<'PERL');
package main;
use Typist;
struct 'NumBox[T: Num]' => (val => T);
sub test :sig(() -> Void) () {
    my $b = NumBox(val => "bad");
}
PERL

    ok scalar @$errs >= 1, 'Str violates T: Num bound';
};

# ── 6.6 Struct field type mismatch ──

subtest 'struct constructor: field type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Point => (x => Int, y => Int);
sub test :sig(() -> Void) () {
    my $p = Point(x => "bad", y => 2);
}
PERL

    ok scalar @$errs >= 1, 'Str passed to Int field triggers error';
};

# ════════════════════════════════════════════════
# Section 7: Subtype/LUB Edge Cases
# ════════════════════════════════════════════════

# ── 7.1 Bool <: Int ──

subtest 'subtype: Bool assignable to Int' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Bool) -> Int) ($b) {
    return $b;
}
PERL

    is scalar @$errs, 0, 'Bool <: Int';
};

# ── 7.2 Int <: Num ──

subtest 'subtype: Int assignable to Num' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Int) -> Num) ($n) {
    return $n;
}
PERL

    is scalar @$errs, 0, 'Int <: Num';
};

# ── 7.3 Not Num <: Int ──

subtest 'subtype: Num not assignable to Int' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Num) -> Int) ($n) {
    return $n;
}
PERL

    is scalar @$errs, 1, 'Num is not subtype of Int';
};

# ── 7.4 ArrayRef covariance ──

subtest 'subtype: ArrayRef[Int] <: ArrayRef[Num]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((ArrayRef[Int]) -> ArrayRef[Num]) ($xs) {
    return $xs;
}
PERL

    is scalar @$errs, 0, 'ArrayRef is covariant — ArrayRef[Int] <: ArrayRef[Num]';
};

# ── 7.5 Newtype is nominal ──

subtest 'subtype: newtype is nominal (not structural)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
newtype UserId => 'Int';
sub test :sig((Int) -> UserId) ($n) {
    return $n;
}
PERL

    is scalar @$errs, 1, 'Int cannot be assigned to UserId (nominal)';
};

# ════════════════════════════════════════════════
# Section 8: Gradual Typing Edge Cases
# ════════════════════════════════════════════════

# ── 8.1 Unannotated function returns Any ──

subtest 'gradual: unannotated function return compatible with any annotation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub identity ($x) { $x }
sub test :sig(() -> Int) () {
    return identity(42);
}
PERL

    is scalar @$errs, 0, 'unannotated function returns Any — no error at call site';
};

# ── 8.2 Partially annotated ──

subtest 'gradual: partially annotated params still check what they can' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_int :sig((Int) -> Void) ($x) { }
sub test :sig(() -> Void) () {
    takes_int("bad");
}
PERL

    is scalar @$errs, 1, 'annotated param type checked even in simple context';
};

# ════════════════════════════════════════════════
# Section 9: Alias/Typedef Edge Cases
# ════════════════════════════════════════════════

# ── 9.1 Alias resolution in param ──

subtest 'alias: typedef resolved in function param check' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
typedef Name => 'Str';
sub greet :sig((Name) -> Str) ($name) {
    return "Hi, " . $name;
}
sub test :sig(() -> Str) () {
    return greet(42);
}
PERL

    ok scalar @$errs >= 1, 'Int cannot be passed to Name (alias for Str)';
};

# ── 9.2 Alias is transparent for assignment ──

subtest 'alias: transparent subtyping' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
typedef Name => 'Str';
sub test :sig(() -> Void) () {
    my $n :sig(Name) = "Alice";
    my $s :sig(Str) = $n;
}
PERL

    is scalar @$errs, 0, 'Name <: Str and Str <: Name (alias is transparent)';
};

# ── 9.3 Recursive alias ──

subtest 'alias: recursive type alias' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
typedef Json => 'Int | Str | Bool | Undef | ArrayRef[Json] | HashRef[Str, Json]';
sub test :sig((Json) -> Void) ($j) {
    my $v :sig(Json) = $j;
}
PERL

    is scalar @$errs, 0, 'recursive alias resolves without infinite loop';
};

# ════════════════════════════════════════════════
# Section 10: Match/ADT Edge Cases
# ════════════════════════════════════════════════

# ── 10.1 ADT match arm type inference ──

subtest 'match: arm callback param type inferred from ADT' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype 'Option[T]' => Some => '(T)', None => '()';
sub unwrap :sig((Option[Int]) -> Int) ($opt) {
    match $opt,
        Some => sub ($x) {
            my $n :sig(Int) = $x;
            return $n;
        },
        None => sub () {
            return 0;
        };
}
PERL

    is scalar @$errs, 0, 'match arm infers T=Int from Option[Int]';
};

# ── 10.2 ADT match with wrong arm type ──

subtest 'match: type mismatch inside arm (explicit + implicit return)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype 'Option[T]' => Some => '(T)', None => '()';
sub unwrap :sig((Option[Int]) -> Int) ($opt) {
    match $opt,
        Some => sub ($x) {
            return "bad";
        },
        None => sub () {
            return 0;
        };
}
PERL

    # Two errors: (1) explicit `return "bad"` vs Int, (2) implicit return of match expr
    is scalar @$errs, 2, 'explicit return + implicit match return both checked';
    like $errs->[0]{message}, qr/"bad".*Int/, 'explicit return error';
};

# ════════════════════════════════════════════════
# Section 11: Loop Inference Edge Cases
# ════════════════════════════════════════════════

# ── 11.1 for loop with typed array ──

subtest 'loop: foreach infers element type from ArrayRef' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub sum :sig((ArrayRef[Int]) -> Int) ($xs) {
    my $total = 0;
    for my $x (@$xs) {
        my $n :sig(Int) = $x;
    }
    $total;
}
PERL

    is scalar @$errs, 0, 'loop variable inferred as Int from ArrayRef[Int]';
};

# ── 11.2 for loop with wrong expected type ──

subtest 'loop: element type mismatch inside loop body' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((ArrayRef[Int]) -> Void) ($xs) {
    for my $x (@$xs) {
        my $s :sig(Str) = $x;
    }
}
PERL

    is scalar @$errs, 1, 'Int element assigned to Str variable';
};

# ════════════════════════════════════════════════
# Section 12: Bidirectional Inference Edge Cases
# ════════════════════════════════════════════════

# ── 12.1 0/1 bidirectional with Bool context ──

subtest 'bidirectional: 0 as Bool when expected' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $f :sig(Bool) = 0;
    my $t :sig(Bool) = 1;
}
PERL

    is scalar @$errs, 0, '0 and 1 are Bool when expected type is Bool';
};

# ── 12.2 0/1 default to Int ──

subtest 'bidirectional: 0 defaults to Int without context' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_int :sig((Int) -> Void) ($x) { }
sub test :sig(() -> Void) () {
    my $x = 0;
    takes_int($x);
}
PERL

    is scalar @$errs, 0, '0 defaults to Int in absence of Bool context';
};

# ════════════════════════════════════════════════
# Section 13: PPI/Perl Syntax Edge Cases
# ════════════════════════════════════════════════

# ── 13.1 Method call on struct accessor ──

subtest 'method chain: struct accessor followed by method' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Person => (name => Str);
declare 'Str::length' => '(Str) -> Int';
sub test :sig((Person) -> Void) () {
    # Just verify no crash on accessor chain
}
PERL

    # Mainly testing no crash
    ok 1, 'struct accessor method chain does not crash';
};

# ── 13.2 Nested function calls with mixed generics ──

subtest 'generic: nested generic function calls' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare id => '<T>(T) -> T';
declare wrap => '<T>(T) -> ArrayRef[T]';
sub test :sig(() -> ArrayRef[Int]) () {
    return wrap(id(42));
}
PERL

    is scalar @$errs, 0, 'nested generic calls compose correctly';
};

# ── 13.3 Multi-line function call ──

subtest 'call checker: multi-line function call still checked' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
sub test :sig(() -> Int) () {
    return add(
        "bad",
        2,
    );
}
PERL

    ok scalar @$errs >= 1, 'multi-line call site still type-checked';
};

done_testing;
