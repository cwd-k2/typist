use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::Analyze qw(analyze type_errors arity_errors all_errors diags_of_kind);

# ════════════════════════════════════════════════
# Section 1: Complex Expression Inference
# ════════════════════════════════════════════════

# ── 1.1 Nested ternary ──

subtest 'inference: nested ternary produces correct type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub classify :sig((Int) -> Str) ($n) {
    my $label = $n > 0 ? "positive" : $n < 0 ? "negative" : "zero";
    return $label;
}
PERL

    is scalar @$errs, 0, 'nested ternary: LUB(Str, Str, Str) = Str';
};

# ── 1.2 Ternary with Int and Double ──

subtest 'inference: ternary Int/Double widened to Num' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub pick :sig((Bool) -> Num) ($flag) {
    return $flag ? 42 : 3.14;
}
PERL

    is scalar @$errs, 0, 'ternary LUB(Int, Double) = Num accepted';
};

# ── 1.3 Defined-or with function call ──

subtest 'inference: defined-or with function call' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub default_port :sig(() -> Int) () { 8080 }
sub get_port :sig((Maybe[Int]) -> Int) ($port) {
    return $port // default_port();
}
PERL

    is scalar @$errs, 0, 'defined-or: Maybe[Int] // Int → Int';
};

# ── 1.4 String repetition ──

subtest 'inference: x operator produces Str' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub repeat :sig((Str, Int) -> Str) ($s, $n) {
    my $r = $s x $n;
    return $r;
}
PERL

    is scalar @$errs, 0, 'x operator inferred as Str';
};

# ── 1.5 Chained arithmetic ──

subtest 'inference: chained arithmetic preserves numeric type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub calc :sig((Int, Int, Int) -> Int) ($a, $b, $c) {
    my $r = $a + $b * $c - 1;
    return $r;
}
PERL

    is scalar @$errs, 0, 'chained arithmetic stays numeric';
};

# ── 1.6 Mixed string comparison ──

subtest 'inference: string comparison (eq) produces Bool' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub same :sig((Str, Str) -> Bool) ($a, $b) {
    my $r = $a eq $b;
    return $r;
}
PERL

    is scalar @$errs, 0, 'eq operator inferred as Bool';
};

# ── 1.7 Array ref literal ──

subtest 'inference: array ref literal with typed elements' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> ArrayRef[Int]) () {
    return [1, 2, 3];
}
PERL

    is scalar @$errs, 0, '[1, 2, 3] inferred as ArrayRef[Int]';
};

# ── 1.8 Empty array ref ──

subtest 'inference: empty array ref is compatible' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> ArrayRef[Int]) () {
    return [];
}
PERL

    is scalar @$errs, 0, 'empty [] is compatible with ArrayRef[Int]';
};

# ── 1.9 Hash ref literal ──

subtest 'inference: hash ref literal produces Record or HashRef' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $h :sig(HashRef[Str, Int]) = +{ a => 1, b => 2 };
}
PERL

    is scalar @$errs, 0, 'hash ref literal compatible with HashRef[Str, Int]';
};

# ── 1.10 Regex match result ──

subtest 'inference: regex match produces Bool' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub contains :sig((Str) -> Bool) ($s) {
    my $r = $s =~ /pattern/;
    return $r;
}
PERL

    is scalar @$errs, 0, '=~ inferred as Bool';
};

# ════════════════════════════════════════════════
# Section 2: Local Variable Inference Across Scopes
# ════════════════════════════════════════════════

# ── 2.1 Variable inferred in if block, used after ──

subtest 'locals: inferred var used across branch boundary' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_int :sig((Int) -> Void) ($x) { }
sub test :sig(() -> Void) () {
    my $x = 1;
    if (1) {
        takes_int($x);
    }
    takes_int($x);
}
PERL

    is scalar @$errs, 0, 'local inferred before branch is visible both inside and after';
};

# ── 2.2 Multiple assignments do not cross-contaminate ──

subtest 'locals: sequential assignments to different vars' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_int :sig((Int) -> Void) ($x) { }
sub takes_str :sig((Str) -> Void) ($x) { }
sub test :sig(() -> Void) () {
    my $a = 1;
    my $b = "hello";
    takes_int($a);
    takes_str($b);
}
PERL

    is scalar @$errs, 0, 'different locals infer independently';
};

# ── 2.3 Shadowed variable in inner scope ──

subtest 'locals: inner scope shadows outer variable' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($x) { }
sub test :sig(() -> Void) () {
    my $x = 1;
    {
        my $x = "inner";
        takes_str($x);
    }
}
PERL

    is scalar @$errs, 0, 'inner $x shadows outer — Str checked correctly';
};

# ── 2.4 Variable from function call ──

subtest 'locals: variable inferred from function return type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub get_name :sig(() -> Str) () { "Alice" }
sub takes_str :sig((Str) -> Void) ($x) { }
sub test :sig(() -> Void) () {
    my $name = get_name();
    takes_str($name);
}
PERL

    is scalar @$errs, 0, 'local inferred from annotated function return';
};

# ── 2.5 Variable from method call ──

subtest 'locals: variable inferred from struct accessor' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Person => (name => Str, age => Int);
sub takes_str :sig((Str) -> Void) ($x) { }
sub test :sig((Person) -> Void) ($p) {
    my $name = $p->name;
    takes_str($name);
}
PERL

    is scalar @$errs, 0, 'local inferred from struct accessor return type';
};

# ════════════════════════════════════════════════
# Section 3: Generic Instantiation Edge Cases
# ════════════════════════════════════════════════

# ── 3.1 Generic function with multiple type vars ──

subtest 'generic: two type vars independently bound' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare pair => '<A, B>(A, B) -> Tuple[A, B]';
sub test :sig(() -> Tuple[Int, Str]) () {
    return pair(1, "hello");
}
PERL

    is scalar @$errs, 0, 'A=Int, B=Str bound independently';
};

# ── 3.2 Generic with nested parameterized type ──

subtest 'generic: nested param type instantiation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare flatten => '<T>(ArrayRef[ArrayRef[T]]) -> ArrayRef[T]';
sub test :sig(() -> ArrayRef[Int]) () {
    return flatten([[1, 2], [3, 4]]);
}
PERL

    is scalar @$errs, 0, 'T=Int through nested ArrayRef';
};

# ── 3.3 Generic with return type mismatch ──

subtest 'generic: return type mismatch after instantiation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare id => '<T>(T) -> T';
sub test :sig(() -> Str) () {
    return id(42);
}
PERL

    is scalar @$errs, 1, 'id(42) returns Int, not Str';
};

# ── 3.4 Generic with callback that constrains return ──

subtest 'generic: callback return constrains overall return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare apply => '<A, B>(A, (A) -> B) -> B';
sub test :sig(() -> Str) () {
    return apply(42, sub ($n) { "$n" });
}
PERL

    is scalar @$errs, 0, 'B=Str from callback return type';
};

# ── 3.5 Generic identity composed ──

subtest 'generic: identity function composed with itself' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare id => '<T>(T) -> T';
sub test :sig(() -> Int) () {
    return id(id(id(42)));
}
PERL

    is scalar @$errs, 0, 'triply nested id(id(id(42))) returns Int';
};

# ════════════════════════════════════════════════
# Section 4: ADT/Datatype Edge Cases
# ════════════════════════════════════════════════

# ── 4.1 Option type basic use ──

subtest 'ADT: Option[Int] constructor Some/None' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype 'Option[T]' => Some => '(T)', None => '()';
sub test :sig(() -> Void) () {
    my $a :sig(Option[Int]) = Some(42);
    my $b :sig(Option[Int]) = None();
}
PERL

    is scalar @$errs, 0, 'Some(42) and None() both produce Option[Int]';
};

# ── 4.2 Option with wrong inner type ──

subtest 'ADT: wrong inner type in constructor' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype 'Option[T]' => Some => '(T)', None => '()';
sub test :sig(() -> Void) () {
    my $a :sig(Option[Int]) = Some("bad");
}
PERL

    ok scalar @$errs >= 1, 'Some("bad") does not match Option[Int]';
};

# ── 4.3 Nested ADT ──

subtest 'ADT: nested datatype' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype 'Option[T]' => Some => '(T)', None => '()';
sub test :sig(() -> Void) () {
    my $nested :sig(Option[Option[Int]]) = Some(Some(42));
}
PERL

    is scalar @$errs, 0, 'nested Some(Some(42)) produces Option[Option[Int]]';
};

# ── 4.4 Nullary datatype with match ──

subtest 'ADT: nullary datatype exhaustiveness with all arms' => sub {
    my $errs = diags_of_kind(<<'PERL', 'NonExhaustiveMatch');
use v5.40;
datatype Color => Red => '()', Green => '()', Blue => '()';
sub name :sig((Color) -> Str) ($c) {
    match $c,
        Red   => sub () { "red" },
        Green => sub () { "green" },
        Blue  => sub () { "blue" };
}
PERL

    is scalar @$errs, 0, 'all arms covered — no exhaustiveness error';
};

# ── 4.5 Missing arm ──

subtest 'ADT: nullary datatype exhaustiveness with missing arm' => sub {
    my $errs = diags_of_kind(<<'PERL', 'NonExhaustiveMatch');
use v5.40;
datatype Color => Red => '()', Green => '()', Blue => '()';
sub name :sig((Color) -> Str) ($c) {
    match $c,
        Red   => sub () { "red" },
        Green => sub () { "green" };
}
PERL

    is scalar @$errs, 1, 'missing Blue arm detected';
    like $errs->[0]{message}, qr/Blue/, 'error mentions Blue';
};

# ── 4.6 Fallback arm ──

subtest 'ADT: fallback arm suppresses exhaustiveness' => sub {
    my $errs = diags_of_kind(<<'PERL', 'NonExhaustiveMatch');
use v5.40;
datatype Color => Red => '()', Green => '()', Blue => '()';
sub name :sig((Color) -> Str) ($c) {
    match $c,
        Red => sub () { "red" },
        _   => sub () { "other" };
}
PERL

    is scalar @$errs, 0, 'fallback _ suppresses exhaustiveness error';
};

# ════════════════════════════════════════════════
# Section 5: Struct Derive Edge Cases
# ════════════════════════════════════════════════

subtest 'struct derive: basic derive preserves type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Point => (x => Int, y => Int);
sub test :sig((Point) -> Point) ($p) {
    return Point::derive($p, x => 10);
}
PERL

    is scalar @$errs, 0, 'derive with valid field update passes';
};

subtest 'struct derive: field type mismatch in update' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Point => (x => Int, y => Int);
sub test :sig((Point) -> Point) ($p) {
    return Point::derive($p, x => "bad");
}
PERL

    ok scalar @$errs >= 1, 'derive with Str on Int field detected';
};

subtest 'struct derive: unknown field in update' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Point => (x => Int, y => Int);
sub test :sig((Point) -> Point) ($p) {
    return Point::derive($p, z => 10);
}
PERL

    ok scalar @$errs >= 1, 'derive with unknown field z detected';
    like $errs->[0]{message}, qr/unknown field.*z/i, 'error mentions field z';
};

subtest 'struct derive: base arg type checked' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Point => (x => Int, y => Int);
struct Size => (w => Int, h => Int);
sub test :sig((Size) -> Point) ($s) {
    return Point::derive($s, x => 10);
}
PERL

    ok scalar @$errs >= 1, 'derive with wrong base type detected';
};

# ════════════════════════════════════════════════
# Section 6: Complex Narrowing Interactions
# ════════════════════════════════════════════════

# ── 6.1 Narrowing with early return in nested if ──

subtest 'narrowing: early return in nested if' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Int], Bool) -> Int) ($x, $flag) {
    if ($flag) {
        return 0 unless defined $x;
        return $x;
    }
    return 0;
}
PERL

    is scalar @$errs, 0, 'early return inside nested if narrows correctly';
};

# ── 6.2 Multiple narrowing of same variable ──

subtest 'narrowing: isa after defined on same var' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Any]) -> Void) ($x) {
    return unless defined $x;
    my $v :sig(Any) = $x;
}
PERL

    is scalar @$errs, 0, 'defined narrows Maybe[Any] to Any';
};

# ── 6.3 Narrowing with union type ──

subtest 'narrowing: defined on Int | Undef' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Int | Undef) -> Void) ($x) {
    if (defined($x)) {
        my $n :sig(Int) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'defined narrows Int | Undef to Int';
};

# ════════════════════════════════════════════════
# Section 7: Assignment Check Edge Cases
# ════════════════════════════════════════════════

subtest 'assignment: re-assignment to annotated var checked' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x :sig(Int) = 1;
    $x = "bad";
}
PERL

    is scalar @$errs, 1, 're-assignment of Str to Int var detected';
};

subtest 'assignment: valid re-assignment passes' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x :sig(Int) = 1;
    $x = 2;
}
PERL

    is scalar @$errs, 0, 're-assignment of Int to Int var passes';
};

subtest 'assignment: subtype re-assignment passes' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x :sig(Num) = 1.0;
    $x = 42;
}
PERL

    is scalar @$errs, 0, 'Int assigned to Num var passes (Int <: Num)';
};

# ════════════════════════════════════════════════
# Section 8: Map/Grep/Sort Inference
# ════════════════════════════════════════════════

subtest 'map: block form infers Array return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((ArrayRef[Int]) -> Void) ($xs) {
    my @doubled = map { $_ * 2 } @$xs;
    my $v :sig(Array[Int]) = @doubled;
}
PERL

    is scalar @$errs, 0, 'map { $_ * 2 } @$xs produces Array[Int]';
};

subtest 'grep: block form infers Array return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((ArrayRef[Int]) -> Void) ($xs) {
    my @even = grep { $_ % 2 == 0 } @$xs;
    my $v :sig(Array[Int]) = @even;
}
PERL

    is scalar @$errs, 0, 'grep preserves element type';
};

# ════════════════════════════════════════════════
# Section 9: Boundary / Stress Tests
# ════════════════════════════════════════════════

subtest 'stress: many parameters' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub many :sig((Int, Int, Int, Int, Int) -> Int) ($a, $b, $c, $d, $e) {
    $a + $b + $c + $d + $e;
}
sub test :sig(() -> Int) () {
    return many(1, 2, 3, 4, 5);
}
PERL

    is scalar @$errs, 0, '5-param function with 5 args passes arity';
};

subtest 'stress: many params wrong arity' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub many :sig((Int, Int, Int, Int, Int) -> Int) ($a, $b, $c, $d, $e) {
    $a + $b + $c + $d + $e;
}
sub test :sig(() -> Int) () {
    return many(1, 2, 3);
}
PERL

    is scalar @$errs, 1, '3 args to 5-param function triggers arity error';
};

subtest 'stress: deeply nested generic' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare id => '<T>(T) -> T';
sub test :sig(() -> ArrayRef[ArrayRef[Int]]) () {
    return id(id([[1, 2], [3, 4]]));
}
PERL

    is scalar @$errs, 0, 'deeply nested generic instantiation passes';
};

subtest 'stress: long method chain does not crash' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
struct Node => (value => Int, optional(next => Node));
sub test :sig((Node) -> Void) ($n) {
    my $v = $n->value;
}
PERL

    # Just verify no crash
    ok 1, 'recursive struct with accessor does not crash';
};

# ════════════════════════════════════════════════
# Section: Ternary structural equality (equals vs to_string)
# ════════════════════════════════════════════════

subtest 'inference: ternary with structurally equal types' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub pick_str :sig((Bool, Str, Str) -> Str) ($flag, $a, $b) {
    return $flag ? $a : $b;
}
PERL

    is scalar @$errs, 0, 'ternary with two Str params uses equals correctly';
};

subtest 'inference: ternary Record branches use equals' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Point => (x => Int, y => Int);
sub pick :sig((Bool, Point, Point) -> Point) ($flag, $a, $b) {
    return $flag ? $a : $b;
}
PERL

    is scalar @$errs, 0, 'ternary with same struct type produces correct result';
};

# ════════════════════════════════════════════════
# Section: Array LUB dedup correctness
# ════════════════════════════════════════════════

subtest 'inference: array literal with mixed numeric types' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub nums :sig(() -> ArrayRef[Num]) () {
    return [1, 2.5, 3];
}
PERL

    is scalar @$errs, 0, 'array with Int and Double elements produces Num';
};

# ════════════════════════════════════════════════
# Section: Chained map/grep/sort inference
# ════════════════════════════════════════════════

subtest 'inference: map over grep chain produces outer block type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub even_labels :sig((ArrayRef[Int]) -> ArrayRef[Str]) ($nums) {
    return [map { "even_$_" } grep { $_ % 2 == 0 } @$nums];
}
PERL

    is scalar @$errs, 0, 'map { Str } grep { } @ints → ArrayRef[Str]';
};

subtest 'inference: map over grep chain type mismatch detected' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub even_labels :sig((ArrayRef[Int]) -> ArrayRef[Int]) ($nums) {
    return [map { "even_$_" } grep { $_ % 2 == 0 } @$nums];
}
PERL

    is scalar @$errs, 1, 'map { Str } grep { } @ints ≠ ArrayRef[Int]';
};

subtest 'inference: grep over map chain preserves inner map type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub long_labels :sig((ArrayRef[Int]) -> ArrayRef[Str]) ($nums) {
    return [grep { length($_) > 3 } map { "item_$_" } @$nums];
}
PERL

    is scalar @$errs, 0, 'grep { } map { Str } @ints → ArrayRef[Str]';
};

subtest 'inference: triple chain map/grep/sort' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub sorted_even_labels :sig((ArrayRef[Int]) -> ArrayRef[Str]) ($nums) {
    return [map { "val_$_" } sort { $a <=> $b } grep { $_ > 0 } @$nums];
}
PERL

    is scalar @$errs, 0, 'map { Str } sort { } grep { } @ints → ArrayRef[Str]';
};

# ════════════════════════════════════════════════
# Section: Adjacent subscript without arrow
# ════════════════════════════════════════════════

subtest 'inference: adjacent subscript without arrow' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub get_first :sig((HashRef[Str, ArrayRef[Int]]) -> Int) ($data) {
    return $data->{items}[0];
}
PERL

    is scalar @$errs, 0, '$data->{items}[0] infers element type (no arrow)';
};

subtest 'inference: adjacent subscript type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub get_first :sig((HashRef[Str, ArrayRef[Int]]) -> Str) ($data) {
    return $data->{items}[0];
}
PERL

    is scalar @$errs, 1, '$data->{items}[0] → Int ≠ Str';
};

# ════════════════════════════════════════════════
# Section: For-loop range variable typing
# ════════════════════════════════════════════════

subtest 'inference: for-loop range variable is Int' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub sum_indices :sig(() -> Int) () {
    my $total :sig(Int) = 0;
    for my $i (0 .. 10) {
        $total = $total + $i;
    }
    return $total;
}
PERL

    is scalar @$errs, 0, 'for my $i (0..10): $i is Int';
};

done_testing;
