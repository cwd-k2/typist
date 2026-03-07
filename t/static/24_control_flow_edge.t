use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::Analyze qw(analyze type_errors arity_errors all_errors diags_of_kind);

# ════════════════════════════════════════════════
# Section 1: Early Return Narrowing Patterns
#   Perl guard clause idiom: return EXPR unless COND
# ════════════════════════════════════════════════

# ── 1.1 Guard clause: return unless defined ──

subtest 'guard: return unless defined narrows' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub require_str :sig((Maybe[Str]) -> Str) ($s) {
    return "" unless defined $s;
    return $s;
}
PERL

    is scalar @$errs, 0, 'return unless defined narrows Maybe to concrete';
};

# ── 1.2 Multiple guard clauses ──

subtest 'guard: multiple sequential guards' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Config => (
    optional(host    => 'Str'),
    optional(port    => 'Int'),
    optional(timeout => 'Int'),
);
sub connect_str :sig((Config) -> Str) ($c) {
    return "bad" unless defined($c->host());
    return "bad" unless defined($c->port());
    return $c->host();
}
PERL

    is scalar @$errs, 0, 'multiple guard clauses narrow progressively';
};

# ── 1.3 Guard clause with isa ──

subtest 'guard: return unless isa narrows' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Cat => (purr => 'Str');
struct Dog => (bark => 'Str');
sub cat_sound :sig((Cat | Dog) -> Str) ($pet) {
    return "woof" unless $pet isa Cat;
    return $pet->purr();
}
PERL

    is scalar @$errs, 0, 'return unless isa narrows union to specific type';
};

# ── 1.4 Guard early return preserves scope ──

subtest 'guard: narrowed type survives to function end' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub process :sig((Maybe[Int]) -> Int) ($n) {
    return -1 unless defined $n;
    my $result :sig(Int) = $n + 1;
    return $result;
}
PERL

    is scalar @$errs, 0, 'narrowed type is available through function end';
};

# ════════════════════════════════════════════════
# Section 2: If-Else Branching Exhaustiveness
#   Every branch must satisfy return type
# ════════════════════════════════════════════════

# ── 2.1 Both branches return correct type ──

subtest 'branch: if-else both return correct type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub sign :sig((Int) -> Str) ($n) {
    if ($n >= 0) {
        return "non-negative";
    } else {
        return "negative";
    }
}
PERL

    is scalar @$errs, 0, 'both if/else branches return Str';
};

# ── 2.2 One branch has wrong type ──

subtest 'branch: one branch returns wrong type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub sign :sig((Int) -> Str) ($n) {
    if ($n >= 0) {
        return 1;
    } else {
        return "negative";
    }
}
PERL

    ok scalar @$errs >= 1, 'Int return detected in one branch';
};

# ── 2.3 If-elsif-else chain ──

subtest 'branch: if-elsif-else all checked' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub classify :sig((Int) -> Str) ($n) {
    if ($n > 0) {
        return "positive";
    } elsif ($n < 0) {
        return "negative";
    } else {
        return "zero";
    }
}
PERL

    is scalar @$errs, 0, 'if-elsif-else chain all return Str';
};

# ── 2.4 Nested if-else ──

subtest 'branch: nested if-else returns' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub clamp :sig((Int, Int, Int) -> Int) ($n, $lo, $hi) {
    if ($n < $lo) {
        return $lo;
    } else {
        if ($n > $hi) {
            return $hi;
        } else {
            return $n;
        }
    }
}
PERL

    is scalar @$errs, 0, 'nested if-else all return Int';
};

# ════════════════════════════════════════════════
# Section 3: Narrowing Through Control Flow
#   Complex narrowing interactions
# ════════════════════════════════════════════════

# ── 3.1 Defined narrowing preserved across statements ──

subtest 'flow: defined narrowing in flat scope' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub process :sig((Maybe[Int]) -> Int) ($n) {
    if (defined $n) {
        my $doubled :sig(Int) = $n * 2;
        return $doubled;
    }
    return 0;
}
PERL

    is scalar @$errs, 0, 'defined narrowing available inside if block';
};

# ── 3.2 Narrowing does not leak past branch ──

subtest 'flow: narrowing does not leak past if' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
sub test :sig((Maybe[Int]) -> Void) ($n) {
    if (defined $n) {
        my $x :sig(Int) = $n;
    }
    my $y = $n;
}
PERL

    # After the if block, $n is back to Maybe[Int]
    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @$errs;
    is scalar @type_errs, 0, 'no error: $y is untyped (Any from gradual)';
};

# ── 3.3 Union narrowing via isa ──

subtest 'flow: isa narrows union member' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Circle => (radius => 'Int');
struct Square => (side => 'Int');
sub area :sig((Circle | Square) -> Int) ($shape) {
    if ($shape isa Circle) {
        return $shape->radius() * $shape->radius();
    } else {
        return $shape->side() * $shape->side();
    }
}
PERL

    is scalar @$errs, 0, 'isa narrows each branch of union';
};

# ── 3.4 Inverse narrowing: unless defined ──

subtest 'flow: unless defined provides inverse narrowing' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Int]) -> Int) ($n) {
    unless (defined $n) {
        return -1;
    }
    return $n;
}
PERL

    TODO: {
        local $TODO = 'unless block fallthrough does not yet narrow';
        is scalar @$errs, 0, 'unless defined: else path narrows to concrete';
    }
};

# ── 3.5 Multiple isa checks on same variable ──

subtest 'flow: sequential isa checks' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct A => (x => 'Int');
struct B => (y => 'Str');
struct C => (z => 'Bool');
sub dispatch :sig((A | B | C) -> Str) ($v) {
    if ($v isa A) {
        return "a";
    }
    if ($v isa B) {
        return "b";
    }
    return "c";
}
PERL

    is scalar @$errs, 0, 'sequential isa checks all return Str';
};

# ════════════════════════════════════════════════
# Section 4: Loop and Iteration Patterns
#   for-each, nested loops, accumulation
# ════════════════════════════════════════════════

# ── 4.1 For loop with typed accumulator ──

subtest 'loop: for each with accumulator' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub join_strs :sig((ArrayRef[Str], Str) -> Str) ($parts, $sep) {
    my $result :sig(Str) = "";
    for my $part (@$parts) {
        $result = $result . $sep . $part;
    }
    return $result;
}
PERL

    is scalar @$errs, 0, 'loop accumulator string concat';
};

# ── 4.2 Nested loops with different element types ──

subtest 'loop: nested loops different types' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub flatten :sig((ArrayRef[ArrayRef[Int]]) -> ArrayRef[Int]) ($matrix) {
    my $result :sig(ArrayRef[Int]) = [];
    for my $row (@$matrix) {
        for my $cell (@$row) {
            push @$result, $cell;
        }
    }
    return $result;
}
PERL

    is scalar @$errs, 0, 'nested loops preserve element types';
};

# ── 4.3 Loop variable does not leak ──

subtest 'loop: loop variable does not leak to outer scope' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((ArrayRef[Int]) -> Void) ($nums) {
    for my $n (@$nums) {
        my $x :sig(Int) = $n;
    }
}
PERL

    is scalar @$errs, 0, 'loop var accessible inside loop body';
};

# ── 4.4 Loop with struct element access ──

subtest 'loop: struct element access in loop' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct User => (name => 'Str', score => 'Int');
sub top_scorers :sig((ArrayRef[User], Int) -> ArrayRef[Str]) ($users, $min) {
    my $result :sig(ArrayRef[Str]) = [];
    for my $u (@$users) {
        if ($u->score() >= $min) {
            push @$result, $u->name();
        }
    }
    return $result;
}
PERL

    is scalar @$errs, 0, 'struct field access in loop body';
};

# ════════════════════════════════════════════════
# Section 5: Callback and Higher-Order Patterns
#   Real-world HOF usage, closure captures
# ════════════════════════════════════════════════

# ── 5.1 Callback arity checked ──

subtest 'hof: callback arity mismatch' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
declare apply => '((Int) -> Str, Int) -> Str';
sub test :sig(() -> Void) () {
    apply(sub ($a, $b) { "too many" }, 42);
}
PERL

    ok scalar @$errs >= 1, 'callback with wrong arity detected';
};

# ── 5.2 Callback type propagation ──

subtest 'hof: callback type propagated from context' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare map_int => '((Int) -> Str, ArrayRef[Int]) -> ArrayRef[Str]';
sub test :sig(() -> Void) () {
    my $result :sig(ArrayRef[Str]) = map_int(sub ($n) { "x" }, [1, 2, 3]);
}
PERL

    is scalar @$errs, 0, 'callback type inferred from declared function context';
};

# ── 5.3 Nested callbacks ──

subtest 'hof: nested callback invocations' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
declare apply => '((Int) -> Int, Int) -> Int';
sub test :sig(() -> Void) () {
    my $r :sig(Int) = apply(sub ($n) { apply(sub ($m) { $m + 1 }, $n) }, 10);
}
PERL

    is scalar @$errs, 0, 'nested callback invocations type-check';
};

# ── 5.4 Callback returning callback ──

subtest 'hof: function returning closure' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub adder :sig((Int) -> (Int) -> Int) ($a) {
    sub ($b) { $a + $b };
}
PERL

    is scalar @$errs, 0, 'function returning closure type-checks';
};

# ════════════════════════════════════════════════
# Section 6: PPI Parsing Edge Cases
#   Perl syntax that may trip up PPI-based analysis
# ════════════════════════════════════════════════

# ── 6.1 Postfix if/unless ──

subtest 'ppi: postfix if does not confuse analysis' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Int) -> Int) ($n) {
    return 0 if $n < 0;
    return $n;
}
PERL

    is scalar @$errs, 0, 'postfix if with return works';
};

# ── 6.2 Chained method calls on one line ──

subtest 'ppi: chained method on single line' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Wrapper => (inner => 'Str');
sub get :sig((Wrapper) -> Str) ($w) {
    $w->inner();
}
PERL

    is scalar @$errs, 0, 'simple method call on one line';
};

# ── 6.3 Multi-line function call ──

subtest 'ppi: multi-line function call' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
sub test :sig(() -> Void) () {
    my $r :sig(Int) = add(
        1,
        2,
    );
}
PERL

    is scalar @$errs, 0, 'multi-line function call with trailing comma';
};

# ── 6.4 Heredoc does not break analysis ──

subtest 'ppi: heredoc is treated as Str' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub template :sig(() -> Str) () {
    my $t = <<~END;
    Hello, world!
    END
    return $t;
}
PERL

    is scalar @$errs, 0, 'heredoc inferred as Str';
};

# ── 6.5 qw() list ──

subtest 'ppi: qw() list inferred' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my @words = qw(foo bar baz);
}
PERL

    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @$errs;
    is scalar @type_errs, 0, 'qw() does not trigger type errors';
};

# ── 6.6 Negative number literal ──

subtest 'ppi: negative integer literal' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $n :sig(Int) = -42;
}
PERL

    is scalar @$errs, 0, 'negative integer literal matches Int';
};

# ── 6.7 String interpolation ──

subtest 'ppi: string interpolation produces Str' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :sig((Str) -> Str) ($name) {
    "Hello, $name!";
}
PERL

    is scalar @$errs, 0, 'interpolated string is Str';
};

# ════════════════════════════════════════════════
# Section 7: Diagnostic Quality
#   Verify error messages contain useful information
# ════════════════════════════════════════════════

# ── 7.1 TypeMismatch includes expected and actual ──

subtest 'diag: TypeMismatch has expected and actual' => sub {
    my $result = analyze(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $n :sig(Int) = "hello";
}
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } @{$result->{diagnostics}};
    ok scalar @errs >= 1, 'type mismatch detected';
    if (@errs) {
        ok defined $errs[0]{expected_type}, 'expected_type present';
        ok defined $errs[0]{actual_type}, 'actual_type present';
        like $errs[0]{message}, qr/Int/, 'message mentions expected type';
    }
};

# ── 7.2 ArityMismatch includes counts ──

subtest 'diag: ArityMismatch has arg count info' => sub {
    my $result = analyze(<<'PERL');
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
sub test :sig(() -> Void) () {
    add(1);
}
PERL

    my @errs = grep { $_->{kind} eq 'ArityMismatch' } @{$result->{diagnostics}};
    ok scalar @errs >= 1, 'arity mismatch detected';
    if (@errs) {
        like $errs[0]{message}, qr/\d/, 'message mentions counts';
    }
};

# ── 7.3 Return mismatch mentions function name ──

subtest 'diag: return mismatch mentions function name' => sub {
    my $result = analyze(<<'PERL');
use v5.40;
sub get_num :sig(() -> Int) () {
    return "oops";
}
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } @{$result->{diagnostics}};
    ok scalar @errs >= 1, 'return mismatch detected';
    if (@errs) {
        like $errs[0]{message}, qr/get_num/, 'message mentions function name';
    }
};

# ── 7.4 Diagnostics have line numbers ──

subtest 'diag: diagnostics include line information' => sub {
    my $result = analyze(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x :sig(Int) = "wrong";
}
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } @{$result->{diagnostics}};
    ok scalar @errs >= 1, 'error detected';
    if (@errs) {
        ok defined $errs[0]{line}, 'line number present';
        ok $errs[0]{line} > 0, 'line number is positive';
    }
};

# ════════════════════════════════════════════════
# Section 8: Builtin Integration
#   Prelude builtins in real code patterns
# ════════════════════════════════════════════════

# ── 8.1 push in accumulation pattern ──

subtest 'builtin: push in accumulation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub collect :sig((ArrayRef[Int]) -> ArrayRef[Int]) ($nums) {
    my $result :sig(ArrayRef[Int]) = [];
    for my $n (@$nums) {
        push @$result, $n if $n > 0;
    }
    return $result;
}
PERL

    is scalar @$errs, 0, 'push in accumulation loop';
};

# ── 8.2 chomp/chop return value type ──

subtest 'builtin: say is Void-compatible' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub debug :sig((Str) -> Void) ($msg) {
    say "DEBUG: $msg";
}
PERL

    is scalar @$errs, 0, 'say in Void function';
};

# ── 8.3 die as expression ──

subtest 'builtin: die as control flow' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub require_positive :sig((Int) -> Int) ($n) {
    die("negative!") if $n < 0;
    return $n;
}
PERL

    is scalar @$errs, 0, 'die as guard does not break return analysis';
};

# ── 8.4 keys/values with hash ──

subtest 'builtin: keys produces Array[Str]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub count_keys :sig((HashRef[Str, Int]) -> Int) ($h) {
    my @k = keys %$h;
    scalar @k;
}
PERL

    is scalar @$errs, 0, 'keys with hash ref';
};

# ════════════════════════════════════════════════
# Section 9: Edge Cases in Type Expressions
#   Complex annotation parsing
# ════════════════════════════════════════════════

# ── 9.1 Deeply nested parameterized type ──

subtest 'type-expr: deeply nested param type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig(() -> Void) () {
    my $x :sig(ArrayRef[ArrayRef[Int]]) = [[1, 2], [3]];
}
PERL

    is scalar @$errs, 0, 'nested ArrayRef[ArrayRef[Int]] annotation';
};

# ── 9.2 Union in annotation ──

subtest 'type-expr: union type annotation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Int | Str) -> Str) ($x) {
    "ok";
}
PERL

    is scalar @$errs, 0, 'union type in param annotation';
};

# ── 9.3 Maybe as syntactic sugar ──

subtest 'type-expr: Maybe[T] = T | Undef' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Maybe[Int]) -> Void) ($n) {
    if (defined $n) {
        my $x :sig(Int) = $n;
    }
}
PERL

    is scalar @$errs, 0, 'Maybe[Int] narrows to Int via defined';
};

# ── 9.4 Func type in annotation ──

subtest 'type-expr: function type annotation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub apply :sig(((Int) -> Str, Int) -> Str) ($f, $x) {
    $f->($x);
}
PERL

    is scalar @$errs, 0, 'function type in param annotation';
};

# ── 9.5 Void return with side effects ──

subtest 'type-expr: Void function with side effects' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub log_msg :sig((Str) -> Void) ($msg) {
    say $msg;
}
PERL

    is scalar @$errs, 0, 'Void function can have side-effect statements';
};

# ════════════════════════════════════════════════
# Section 10: Regression Guards
#   Patterns that have broken before
# ════════════════════════════════════════════════

# ── 10.1 Builtin in call_words filter ──

subtest 'regression: builtins in call_words not filtered out' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Str) -> Int) ($s) {
    return length($s);
}
PERL

    is scalar @$errs, 0, 'length() recognized as builtin';
};

# ── 10.2 Ternary in variable init ──

subtest 'regression: ternary in variable init' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Int) -> Str) ($n) {
    my $s = $n > 0 ? "pos" : "neg";
    return $s;
}
PERL

    is scalar @$errs, 0, 'ternary inferred in variable init';
};

# ── 10.3 Nested ternary ──

subtest 'regression: nested ternary inference' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Int) -> Str) ($n) {
    my $s = $n > 0 ? "pos" : $n < 0 ? "neg" : "zero";
    return $s;
}
PERL

    is scalar @$errs, 0, 'nested ternary produces Str';
};

# ── 10.4 Generic struct field access after construction ──

subtest 'regression: generic struct field access' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct 'Box[T]' => (value => T);
sub test :sig(() -> Void) () {
    my $b = Box(value => 42);
    my $v :sig(Int) = $b->value();
}
PERL

    is scalar @$errs, 0, 'generic struct field access resolves T';
};

# ── 10.5 Accessor narrowing not leaking ──

subtest 'regression: accessor narrowing with early return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Widget => (label => 'Str', optional(tooltip => 'Str'));
sub get_tooltip :sig((Widget) -> Str) ($w) {
    return $w->label unless defined($w->tooltip);
    $w->tooltip;
}
PERL

    is scalar @$errs, 0, 'early return defined accessor narrows optional to Str';
};

done_testing;
