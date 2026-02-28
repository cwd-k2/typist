use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;

# Helper: analyze source, return diagnostics of kind TypeMismatch
sub type_errors ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@* ];
}

# Helper: analyze source, return diagnostics of kind ArityMismatch
sub arity_errors ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq 'ArityMismatch' } $result->{diagnostics}->@* ];
}

# ── Variable Initializer Checks ──────────────────

subtest 'variable: detects type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int) = "hello";
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/\$x.*Int/, 'message mentions variable and expected type';
};

subtest 'variable: no error on matching type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int) = 42;
PERL

    is scalar @$errs, 0, 'no errors';
};

subtest 'variable: subtype is allowed (Bool → Int)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int) = 0;
PERL

    is scalar @$errs, 0, 'Bool is subtype of Int';
};

subtest 'variable: Str to Int mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $name :Type(Int) = "alice";
PERL

    is scalar @$errs, 1, 'one error';
};

subtest 'variable: ArrayRef element mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $xs :Type(ArrayRef[Int]) = [1, "two"];
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/ArrayRef/, 'mentions ArrayRef';
};

subtest 'variable: ArrayRef matching' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $xs :Type(ArrayRef[Int]) = [1, 2, 3];
PERL

    is scalar @$errs, 0, 'no errors for matching ArrayRef';
};

subtest 'variable: no init → skip' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int);
PERL

    is scalar @$errs, 0, 'no errors when no initializer';
};

# ── Function Argument Checks ────────────────────

subtest 'call: detects argument mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
add("hello", 2);
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Argument 1.*add/, 'argument 1 of add';
};

subtest 'call: no error on matching args' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
add(3, 4);
PERL

    is scalar @$errs, 0, 'no errors';
};

subtest 'call: subtype arg is allowed' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub process :Type((Num) -> Num) ($x) {
    return $x;
}
process(42);
PERL

    is scalar @$errs, 0, 'Int is subtype of Num';
};

# ── Return Type Checks ─────────────────────────

subtest 'return: detects mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Int) ($name) {
    return "hello";
}
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Return.*greet.*Int/, 'return type mismatch';
};

subtest 'return: no error on matching type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub double :Type((Int) -> Int) ($x) {
    return 42;
}
PERL

    is scalar @$errs, 0, 'no errors';
};

subtest 'return: Any return type → skip' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub foo :Type((Int) -> Any) ($x) {
    return "anything";
}
PERL

    is scalar @$errs, 0, 'no errors with Any return type';
};

# ── Typedef Resolution ──────────────────────────

subtest 'typedef: resolves alias for checking' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
typedef Age => 'Int';
my $age :Type(Age) = "young";
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/\$age/, 'mentions variable';
};

subtest 'typedef: matching alias' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
typedef Age => 'Int';
my $age :Type(Age) = 25;
PERL

    is scalar @$errs, 0, 'no errors';
};

# ── Non-inferable → Skip ────────────────────────

subtest 'skip: variable reference as initializer' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $other = 42;
my $x :Type(Int) = $other;
PERL

    is scalar @$errs, 0, 'skip non-inferable initializer';
};

subtest 'skip: function call as initializer' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int) = get_value();
PERL

    is scalar @$errs, 0, 'skip function call initializer';
};

subtest 'generic: detects structural mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub first :Type(<T>(ArrayRef[T]) -> T) ($arr) {
    return $arr->[0];
}
first("hello");
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Argument 1.*first.*ArrayRef/, 'structural mismatch: Str vs ArrayRef[T]';
};

# ── Generic Function Static Checks ────────────

subtest 'generic: successful instantiation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub first :Type(<T>(ArrayRef[T]) -> T) ($arr) {
    return $arr->[0];
}
first([1, 2, 3]);
PERL

    is scalar @$errs, 0, 'generic call OK: T := Int from ArrayRef[Int]';
};

subtest 'generic: non-inferable argument → skip' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub first :Type(<T>(ArrayRef[T]) -> T) ($arr) {
    return $arr->[0];
}
first($unknown_var);
PERL

    is scalar @$errs, 0, 'skip when argument type cannot be inferred';
};

subtest 'generic: bounded quantification OK' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub max_of :Type(<T: Num>(T, T) -> T) ($a, $b) {
    return $a > $b ? $a : $b;
}
max_of(1, 2);
PERL

    is scalar @$errs, 0, 'max_of(1, 2) OK: T := Int, Int <: Num';
};

subtest 'generic: bounded quantification violation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub max_of :Type(<T: Num>(T, T) -> T) ($a, $b) {
    return $a > $b ? $a : $b;
}
max_of("a", "b");
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/does not satisfy bound.*Num/, 'Str does not satisfy bound Num';
};

subtest 'generic: multiple type variables' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub pair :Type(<T, U>(T, U) -> Str) ($a, $b) {
    return "$a $b";
}
pair(1, "hello");
PERL

    is scalar @$errs, 0, 'pair(1, "hello") OK: T := Int, U := Str';
};

# ── Literal Type Checks ────────────────────────

subtest 'literal: numeric literal matches declared type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int) = 42;
my $y :Type(Num) = 3.14;
my $z :Type(Bool) = 1;
PERL

    is scalar @$errs, 0, 'no errors for matching literals';
};

subtest 'literal: Bool literal matches Int (subtype)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int) = 1;
PERL

    is scalar @$errs, 0, 'Bool literal is subtype of Int';
};

subtest 'literal: string literal matches Str' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Str) = "hello";
PERL

    is scalar @$errs, 0, 'string literal matches Str';
};

subtest 'literal: ArrayRef with mixed literals infers common super' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $xs :Type(ArrayRef[Int]) = [1, 2, 3];
PERL

    is scalar @$errs, 0, 'array of int literals matches ArrayRef[Int]';
};

# ── Function Return Type Propagation ───────────

subtest 'call: infers return type of called function' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
my $x :Type(Str) = greet("world");
PERL

    is scalar @$errs, 0, 'greet() returns Str, assigned to Str — no error';
};

subtest 'call: detects return-type vs variable-type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
my $x :Type(Int) = greet("world");
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/\$x.*Int.*Str/, 'Str vs Int mismatch';
};

subtest 'call: nested call type propagation' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
sub loud :Type((Str) -> Str) ($s) {
    return $s;
}
loud(greet("world"));
PERL

    is scalar @$errs, 0, 'greet() returns Str, loud() accepts Str — no error';
};

subtest 'call: nested call type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
add(greet("world"), 42);
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Argument 1.*add.*Int.*Str/, 'greet returns Str, add expects Int';
};

subtest 'call: nested call with correct arg count' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub double :Type((Int) -> Int) ($x) {
    return $x * 2;
}
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
add(double(3), 42);
PERL

    is scalar @$errs, 0, 'nested call: double(3) returns Int, add(Int, Int) — no error';
};

# ── Variable Symbol Resolution ─────────────────

subtest 'variable: symbol resolves to declared type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub loud :Type((Str) -> Str) ($s) {
    return $s;
}
my $x :Type(Str) = "hi";
loud($x);
PERL

    is scalar @$errs, 0, '$x is Str, loud accepts Str — no error';
};

subtest 'variable: symbol type mismatch at call site' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
my $name :Type(Str) = "alice";
add($name, 42);
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Argument 1.*add.*Int.*Str/, '$name is Str but add expects Int';
};

subtest 'variable: unannotated variable → skip' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
my $x = 42;
add($x, 1);
PERL

    is scalar @$errs, 0, 'unannotated variable — skip check';
};

# ── Unannotated Function → Skip (gradual typing) ─

subtest 'skip: unannotated function call as initializer' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub get_value ($x) {
    return $x;
}
my $y :Type(Int) = get_value(42);
PERL

    is scalar @$errs, 0, 'unannotated function → skip (unknown return type)';
};

subtest 'skip: unannotated function call as argument' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub make_thing ($x) {
    return $x;
}
sub process :Type((Int) -> Int) ($n) {
    return $n;
}
process(make_thing(42));
PERL

    is scalar @$errs, 0, 'unannotated function as arg → skip check';
};

subtest 'skip: partially annotated function (no return type in annotation)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub compute :Type((Int) -> Any) ($n) {
    return $n * 2;
}
my $x :Type(Int) = compute(42);
PERL

    is scalar @$errs, 0, 'Any return type → return type unknown, skip';
};

# ── Flow Typing (unannotated variable inference) ─

subtest 'flow: inferred variable from function call' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
sub loud :Type((Str) -> Str) ($s) {
    return uc($s);
}
my $result = greet("Alice");
loud($result);
PERL

    is scalar @$errs, 0, '$result inferred as Str from greet(), loud(Str) OK';
};

subtest 'flow: inferred variable type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
my $result = greet("Alice");
add($result, 42);
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Argument 1.*add.*Int.*Str/, '$result inferred as Str, add expects Int';
};

subtest 'flow: inferred variable from literal' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
my $x = 42;
add($x, 1);
PERL

    is scalar @$errs, 0, '$x inferred as Int from literal, add(Int, Int) OK';
};

subtest 'flow: inferred variable literal mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
my $name = "hello";
add($name, 1);
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Argument 1.*add.*Int/, '$name inferred from literal, type mismatch with Int';
};

subtest 'flow: inferred variable used in typed init' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
my $result = greet("Alice");
my $x :Type(Int) = $result;
PERL

    # $result is inferred as Str, assigned to :Type(Int) → mismatch
    # Note: this depends on variable-to-variable propagation working
    # Currently _check_variable_initializers infers $result from env
    # which sees it as Str, so Int vs Str is flagged
    is scalar @$errs, 1, '$result inferred Str assigned to Int → error';
};

# ── Symbol Index: inferred types ────────────────

subtest 'symbols: inferred variable type appears in symbol index' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
my $result = greet("Alice");
PERL

    my @vars = grep { $_->{kind} eq 'variable' } $result->{symbols}->@*;
    ok scalar @vars >= 1, 'at least one variable in symbols';
    my ($inferred) = grep { $_->{name} eq '$result' } @vars;
    ok $inferred, '$result appears in symbol index';
    like $inferred->{type}, qr/Str/, '$result type is Str (inferred)';
};

subtest 'symbols: unannotated function shows Eff(*)' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub helper ($x) {
    return $x;
}
PERL

    my @fns = grep { $_->{kind} eq 'function' } $result->{symbols}->@*;
    my ($fn) = grep { $_->{name} eq 'helper' } @fns;
    ok $fn, 'helper in symbols';
    is $fn->{eff_expr}, 'Eff(*)', 'unannotated function shows eff_expr = Eff(*)';
};

# ── Function Parameter Typing ─────────────────

subtest 'return: param type enables return type mismatch detection' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Int) ($name) {
    return $name;
}
PERL

    is scalar @$errs, 1, 'one error: returning Str param as Int';
    like $errs->[0]{message}, qr/Return.*greet.*Int.*Str/, 'detects Str vs Int mismatch';
};

subtest 'return: param type matches return type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub identity :Type((Int) -> Int) ($x) {
    return $x;
}
PERL

    is scalar @$errs, 0, 'no error: returning Int param as Int';
};

subtest 'call: param type used in inner call site check' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
sub wrong :Type((Str) -> Int) ($s) {
    return add($s, 1);
}
PERL

    is scalar @$errs, 1, 'one error: Str param passed to Int arg';
    like $errs->[0]{message}, qr/Argument 1.*add.*Int.*Str/, 'detects param type mismatch at inner call';
};

# ── @typist-ignore ────────────────────────────────

# ── Implicit Return Type Checks ───────────────

subtest 'implicit return: detects mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Int) ($name) {
    "hello"
}
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Implicit return.*greet.*Int/, 'implicit return type mismatch';
};

subtest 'implicit return: no error on matching type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub answer :Type(() -> Int) () {
    42
}
PERL

    is scalar @$errs, 0, 'no errors';
};

subtest 'implicit return: explicit return does not duplicate' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub double :Type((Int) -> Int) ($x) {
    return $x
}
PERL

    is scalar @$errs, 0, 'no duplicate error for explicit return';
};

subtest 'implicit return: control structure ending is skipped' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub maybe :Type((Int) -> Int) ($x) {
    if ($x > 0) {
        return $x;
    }
}
PERL

    is scalar @$errs, 0, 'no false positive on control structure';
};

subtest 'implicit return: param variable type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub wrong :Type((Str) -> Int) ($name) {
    $name
}
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Implicit return.*wrong.*Int.*Str/, 'param variable Str vs Int';
};

# ── @typist-ignore ────────────────────────────────

subtest '@typist-ignore suppresses TypeMismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
# @typist-ignore
my $x = add("hello", "world");
PERL
    is scalar @$errs, 0, '@typist-ignore suppresses TypeMismatch';
};

subtest '@typist-ignore does not suppress other lines' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
# @typist-ignore
my $x = add("hello", "world");
my $y = add("oops", "bad");
PERL
    ok scalar @$errs >= 1, 'non-ignored line still reports TypeMismatch';
};

# ── Arity Mismatch Checks ─────────────────────

subtest 'arity: too few arguments' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
add(1);
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/add\(\) expects 2 arguments, got 1/, 'too few args message';
};

subtest 'arity: too many arguments' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
add(1, 2, 3);
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/add\(\) expects 2 arguments, got 3/, 'too many args message';
};

subtest 'arity: correct argument count' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
add(1, 2);
PERL

    is scalar @$errs, 0, 'no arity errors';
};

subtest 'arity: zero-argument function called with no args' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub answer :Type(() -> Int) () {
    return 42;
}
answer();
PERL

    is scalar @$errs, 0, 'no arity errors for 0-arg function';
};

subtest 'arity: zero-argument function called with args' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub answer :Type(() -> Int) () {
    return 42;
}
answer(1, 2);
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/answer\(\) expects 0 arguments, got 2/, '0-arg function called with 2 args';
};

subtest 'arity: variadic (last param ArrayRef) allows extra args' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub collect :Type((Str, ArrayRef[Int]) -> Str) ($label, $nums) {
    return $label;
}
collect("test", [1, 2, 3]);
PERL

    is scalar @$errs, 0, 'variadic function allows any arg count';
};

subtest 'arity: too few still caught with type mismatch on excess' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
add(1);
PERL

    is scalar @$errs, 0, 'no type errors on arity mismatch (skipped)';
};

subtest 'arity: nested call counts as one argument' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub double :Type((Int) -> Int) ($x) {
    return $x * 2;
}
sub add :Type((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
add(double(3), 42);
PERL

    is scalar @$errs, 0, 'nested call counted as single argument';
};

# ── Variable Reassignment Checks ───────────────

subtest 'assignment: detects type mismatch on reassignment' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int) = 0;
$x = "hello";
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Assignment to \$x.*Int/, 'message mentions variable and expected type';
};

subtest 'assignment: no error on matching reassignment' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int) = 0;
$x = 42;
PERL

    is scalar @$errs, 0, 'no errors';
};

subtest 'assignment: does not duplicate with variable initializer' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int) = "hello";
PERL

    is scalar @$errs, 1, 'only one error from initializer, not duplicated by assignment check';
};

subtest 'assignment: unannotated variable → skip' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x = 0;
$x = "hello";
PERL

    is scalar @$errs, 0, 'unannotated variable — skip check';
};

subtest 'assignment: subtype is allowed on reassignment' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Num) = 3.14;
$x = 42;
PERL

    is scalar @$errs, 0, 'Int is subtype of Num — allowed';
};

subtest 'assignment: inside function body respects param env' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $x :Type(Int) = 0;
sub mutate :Type(() -> Void) () {
    $x = "oops";
}
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Assignment to \$x.*Int/, 'detects mismatch inside function body';
};

# ── Branch Implicit Return Checks ──────────────

subtest 'branch return: if/else implicit — one branch mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub classify :Type((Int) -> Str) ($n) {
    if ($n > 0) {
        "positive"
    } else {
        42
    }
}
PERL

    is scalar @$errs, 1, 'one error in else branch';
    like $errs->[0]{message}, qr/Implicit return.*classify.*Str/, 'implicit return mismatch in branch';
};

subtest 'branch return: if/else implicit — both branches match' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub classify :Type((Int) -> Str) ($n) {
    if ($n > 0) {
        "positive"
    } else {
        "non-positive"
    }
}
PERL

    is scalar @$errs, 0, 'no errors when both branches match';
};

subtest 'branch return: if only (no else) — branch matches' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub maybe :Type((Int) -> Str) ($n) {
    if ($n > 0) {
        "positive"
    }
}
PERL

    is scalar @$errs, 0, 'no error for matching if branch';
};

subtest 'branch return: if/elsif/else — last branch mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub classify :Type((Int) -> Str) ($n) {
    if ($n > 0) {
        "positive"
    } elsif ($n == 0) {
        "zero"
    } else {
        -1
    }
}
PERL

    is scalar @$errs, 1, 'one error in else branch';
    like $errs->[0]{message}, qr/Implicit return.*classify.*Str/, 'mismatch in else branch';
};

subtest 'branch return: nested if inside else' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub deep :Type((Int) -> Str) ($n) {
    if ($n > 0) {
        "positive"
    } else {
        if ($n == 0) {
            "zero"
        } else {
            99
        }
    }
}
PERL

    is scalar @$errs, 1, 'one error in nested else';
    like $errs->[0]{message}, qr/Implicit return.*deep.*Str/, 'nested branch mismatch detected';
};

subtest 'branch return: explicit return in branches already caught' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub classify :Type((Int) -> Str) ($n) {
    if ($n > 0) {
        return "positive";
    } else {
        return 42;
    }
}
PERL

    is scalar @$errs, 1, 'one error from explicit return in else';
    like $errs->[0]{message}, qr/Return value.*classify.*Str/, 'explicit return mismatch detected';
};

done_testing;
