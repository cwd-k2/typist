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

# ── Type Narrowing (defined) ───────────────────

subtest 'narrowing: Maybe[Str] narrowed to Str inside defined guard' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
my $x :Type(Maybe[Str]) = "alice";
if (defined $x) {
    greet($x);
}
PERL

    is scalar @$errs, 0, 'no error: $x narrowed to Str inside defined guard';
};

subtest 'narrowing: Maybe[Str] not narrowed outside defined guard' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
my $x :Type(Maybe[Str]) = "alice";
greet($x);
PERL

    is scalar @$errs, 1, 'one error: $x is Str | Undef outside guard';
    like $errs->[0]{message}, qr/Argument 1.*greet.*Str/, 'type mismatch with union type';
};

subtest 'narrowing: truthiness condition narrows Maybe to T' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
my $x :Type(Maybe[Str]) = "alice";
if ($x) {
    greet($x);
}
PERL

    is scalar @$errs, 0, 'no error: truthiness narrows Str | Undef to Str';
};

subtest 'narrowing: Union(Int, Str, Undef) narrowed to Union(Int, Str)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub process :Type((Int | Str) -> Str) ($v) {
    return "$v";
}
my $x :Type(Int | Str | Undef) = 42;
if (defined $x) {
    process($x);
}
PERL

    is scalar @$errs, 0, 'no error: Undef removed, Int | Str remains';
};

subtest 'narrowing: defined $x (space-separated form)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
    return "hello $name";
}
my $x :Type(Maybe[Str]) = "alice";
if (defined $x) {
    greet($x);
}
PERL

    is scalar @$errs, 0, 'no error: defined($x) with parens narrows';
};

# ── Variadic Function Arity ──────────────────────

subtest 'variadic: accepts minimum args' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub vfunc :Type((Int, ...Str) -> Int) ($n, @rest) { $n }
vfunc(1);
PERL
    is scalar @$errs, 0, 'no error: minimum args ok';
};

subtest 'variadic: accepts extra args' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub vfunc :Type((Int, ...Str) -> Int) ($n, @rest) { $n }
vfunc(1, "a", "b", "c");
PERL
    is scalar @$errs, 0, 'no error: extra variadic args ok';
};

subtest 'variadic: detects too few args' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub vfunc :Type((Int, ...Str) -> Int) ($n, @rest) { $n }
vfunc();
PERL
    is scalar @$errs, 1, 'one arity error';
    like $errs->[0]{message}, qr/at least 1/, 'message says at least N';
};

subtest 'variadic: rest-only function' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub vfunc :Type((...Int) -> Int) (@nums) { 0 }
vfunc();
vfunc(1);
vfunc(1, 2, 3);
PERL
    is scalar @$errs, 0, 'no error: rest-only accepts 0+ args';
};

subtest 'variadic: type check on variadic args' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub vfunc :Type((Int, ...Str) -> Int) ($n, @rest) { $n }
vfunc(1, "a", "b");
PERL
    is scalar @$errs, 0, 'no error: correct variadic arg types';
};

# ── Datatype Constructor Checks ─────────────────

subtest 'datatype: constructor return type inferred as Data type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype Shape => Circle => '(Int)', Rect => '(Int, Int)';
sub take_int :Type((Int) -> Int) ($x) { $x }
my $r = take_int(Circle(5));
PERL

    ok @$errs > 0, 'Shape is not subtype of Int';
    like $errs->[0]{message}, qr/Shape/, 'mentions Shape in error';
};

subtest 'datatype: constructor arg type checked' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype Shape => Circle => '(Int)', Rect => '(Int, Int)';
Circle("hello");
PERL

    ok @$errs > 0, 'Str arg to Circle(Int) detected';
};

subtest 'datatype: Shape accepted where Shape expected' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype Shape => Circle => '(Int)', Rect => '(Int, Int)';
sub area :Type((Shape) -> Int) ($s) { 42 }
my $r = area(Circle(5));
PERL

    my @all_errs = grep { $_->{kind} =~ /Mismatch/ } @$errs;
    is scalar @all_errs, 0, 'no mismatch when Shape matches Shape';
};

subtest 'datatype: variable init type checked against constructor' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
datatype Shape => Circle => '(Int)', Rect => '(Int, Int)';
my $c :Type(Int) = Circle(5);
PERL

    ok @$errs > 0, 'Shape is not subtype of Int in variable init';
};

# ── Typeclass Method Checks ─────────────────────

subtest 'typeclass: method called correctly' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
typeclass Eq => T => (
    eq => '(T, T) -> Bool',
);
sub check :Type(() -> Bool) () {
    Eq::eq(1, 2);
}
PERL
    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @errs, 0, 'no mismatch for Eq::eq(Int, Int)';
};

subtest 'typeclass: method arity checked' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
typeclass Eq => T => (
    eq => '(T, T) -> Bool',
);
sub check :Type(() -> Bool) () {
    Eq::eq(1);
}
PERL
    my @errs = grep { $_->{kind} eq 'ArityMismatch' } $result->{diagnostics}->@*;
    ok @errs > 0, 'arity mismatch for Eq::eq with 1 arg';
};

subtest 'typeclass: method structural mismatch detected' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
typeclass Showable => T => (
    show => '(ArrayRef[T]) -> Str',
);
sub test :Type(() -> Str) () {
    Showable::show("not_array");
}
PERL
    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    ok @errs > 0, 'structural mismatch: Str vs ArrayRef[T]';
};

subtest 'typeclass: method with () syntax extracted' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
typeclass Show => T => (
    show => '(T) -> Str',
);
PERL
    my $sig = $result->{registry}->lookup_function('Show', 'show');
    ok $sig, 'Show::show registered in registry';
    ok $sig->{returns} && $sig->{returns}->to_string eq 'Str', 'return type is Str';
};

# ── Newtype Constructor Checks ──────────────────

subtest 'newtype: constructor return type is nominal' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
newtype UserId => 'Int';
sub take_str :Type((Str) -> Str) ($x) { $x }
my $r = take_str(UserId(42));
PERL

    ok @$errs > 0, 'UserId is not Str';
};

subtest 'newtype: constructor arg type checked' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
newtype UserId => 'Int';
UserId("hello");
PERL

    ok @$errs > 0, 'Str arg to UserId(Int) detected';
};

subtest 'newtype: correct usage produces no error' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
newtype UserId => 'Int';
sub take_id :Type((UserId) -> Int) ($id) { 0 }
my $r = take_id(UserId(42));
PERL

    is scalar @$errs, 0, 'UserId matches UserId param';
};

# ── GADT Static Analysis ────────────────────────

subtest 'GADT: constructor return type inferred as specific type' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;
datatype 'Expr[A]' =>
    IntLit  => '(Int) -> Expr[Int]',
    BoolLit => '(Bool) -> Expr[Bool]';
sub take_str :Type((Str) -> Str) ($x) { $x }
my $r = take_str(IntLit(42));
PERL
    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    ok @errs > 0, 'Expr[Int] is not subtype of Str';
};

subtest 'GADT: constructor arg type still checked' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;
datatype 'Expr[A]' =>
    IntLit => '(Int) -> Expr[Int]';
IntLit("hello");
PERL
    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    ok @errs > 0, 'Str arg to IntLit(Int) detected';
};

subtest 'GADT: is_gadt in registry' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;
datatype 'Expr[A]' =>
    IntLit => '(Int) -> Expr[Int]';
PERL
    # Just verify no crashes; the GADT data type was registered
    my @errs = grep { $_->{kind} =~ /Mismatch|Error/ } $result->{diagnostics}->@*;
    is scalar @errs, 0, 'GADT registration produces no errors';
};

subtest 'GADT: mixed GADT and normal constructors' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
use Typist;
datatype 'Expr[A]' =>
    IntLit  => '(Int) -> Expr[Int]',
    BoolLit => '(Bool) -> Expr[Bool]',
    Var     => '(Str)';
sub take_int :Type((Int) -> Int) ($x) { $x }
my $r = take_int(Var("x"));
PERL
    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    ok @errs > 0, 'Expr[A] (generic Var) is not Int';
};

# ── Variadic flag propagation for registry functions ──

subtest 'variadic builtin via registry: no false arity error' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
my $s = join(",", "a", "b", "c", "d");
PERL
    is scalar @$errs, 0, 'join with multiple args is not an arity error';
};

subtest 'anonymous sub as argument: correct arity' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub apply :Type((ArrayRef[Int], CodeRef[Int -> Int]) -> ArrayRef[Int]) ($arr, $f) {
    [map { $f->($_) } @$arr]
}
my $r = apply([1, 2, 3], sub ($x) { $x * 2 });
PERL
    is scalar @$errs, 0, 'anonymous sub with signature counted as one arg';
};

# ── Typeclass method generics ──

subtest 'typeclass method: no UndeclaredTypeVar for free vars' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
typeclass MyFn => 'F', +{
    apply => '(F, Int) -> Int',
};
PERL
    my @errs = grep { $_->{kind} eq 'UndeclaredTypeVar' } $result->{diagnostics}->@*;
    is scalar @errs, 0, 'typeclass var F is declared in method generics';
};

# ── Bounded Quantification Body Check ────────────

subtest 'bounded generic body: T:Num used with int()' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub halve :Type(<T: Num>(T) -> T) ($x) {
    int($x / 2);
}
PERL

    is scalar @$errs, 0, 'no errors: T:Num treated as Num in body';
};

subtest 'bounded generic body: T:Num used with arithmetic' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub double_it :Type(<T: Num>(T) -> T) ($x) {
    return $x * 2;
}
PERL

    is scalar @$errs, 0, 'no errors: T:Num in arithmetic context';
};

# ── Column Precision and Structured Fields ──────

subtest 'diagnostic: col and expected/actual_type on variable mismatch' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
my $x :Type(Int) = "hello";
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @errs, 1, 'one TypeMismatch error';
    ok $errs[0]{col} > 0, 'col is set (greater than 0)';
    is $errs[0]{expected_type}, 'Int', 'expected_type is Int';
    like $errs[0]{actual_type}, qr/hello/, 'actual_type contains the inferred type';
};

subtest 'diagnostic: col on call site argument mismatch' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
add("hello", 2);
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @errs, 1, 'one TypeMismatch error';
    ok $errs[0]{col} > 0, 'col is set on call site mismatch';
    is $errs[0]{expected_type}, 'Int', 'expected_type is Int';
    like $errs[0]{actual_type}, qr/hello/, 'actual_type contains the inferred type';
};

subtest 'diagnostic: col on arity mismatch' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
add(1);
PERL

    my @errs = grep { $_->{kind} eq 'ArityMismatch' } $result->{diagnostics}->@*;
    is scalar @errs, 1, 'one ArityMismatch error';
    ok $errs[0]{col} > 0, 'col is set on arity mismatch';
};

subtest 'diagnostic: col and expected/actual_type on return mismatch' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Int) ($name) {
    return "hello";
}
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @errs, 1, 'one TypeMismatch error';
    ok $errs[0]{col} > 0, 'col is set on return mismatch';
    is $errs[0]{expected_type}, 'Int', 'expected_type is Int';
    like $errs[0]{actual_type}, qr/hello/, 'actual_type contains the inferred type';
};

subtest 'diagnostic: col and expected/actual_type on implicit return mismatch' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Int) ($name) {
    "hello"
}
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @errs, 1, 'one TypeMismatch error';
    ok $errs[0]{col} > 0, 'col is set on implicit return mismatch';
    is $errs[0]{expected_type}, 'Int', 'expected_type is Int';
    like $errs[0]{actual_type}, qr/hello/, 'actual_type contains the inferred type';
};

subtest 'diagnostic: col on assignment mismatch' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
my $x :Type(Int) = 0;
$x = "hello";
PERL

    my @errs = grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@*;
    is scalar @errs, 1, 'one TypeMismatch error';
    ok $errs[0]{col} > 0, 'col is set on assignment mismatch';
    is $errs[0]{expected_type}, 'Int', 'expected_type is Int';
    like $errs[0]{actual_type}, qr/hello/, 'actual_type contains the inferred type';
};

# ── Bidirectional Inference (expected type threading) ──

subtest 'bidirectional: hash matches expected struct via return type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub get_config :Type(() -> Record(name => Str, count => Int)) () {
    +{ name => "test", count => 42 }
}
PERL

    is scalar @$errs, 0, 'no mismatch when hash matches expected struct';
};

subtest 'bidirectional: hash mismatch detected via expected struct' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub get_config :Type(() -> Record(name => Str, count => Int)) () {
    +{ name => "test", count => "wrong" }
}
PERL

    is scalar @$errs, 1, 'mismatch detected when hash field type is wrong';
    like $errs->[0]{message}, qr/Implicit return.*get_config/, 'implicit return mismatch';
};

subtest 'bidirectional: variable init passes expected type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $cfg :Type(Record(x => Int, y => Int)) = +{ x => 1, y => 2 };
PERL

    is scalar @$errs, 0, 'no mismatch when hash matches expected struct in variable init';
};

subtest 'bidirectional: array matches expected ArrayRef element type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
my $xs :Type(ArrayRef[Int]) = [1, 2, 3];
PERL

    is scalar @$errs, 0, 'no mismatch for array matching expected ArrayRef';
};

subtest 'bidirectional: expected type flows to call site arg' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub take_struct :Type((Record(a => Int)) -> Int) ($s) { 0 }
take_struct(+{ a => 42 });
PERL

    is scalar @$errs, 0, 'hash arg matches expected struct param';
};

# ── Narrowing: truthiness ──────────────────────

subtest 'narrowing: truthiness removes Undef' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub foo :Type((Int | Undef) -> Int) ($x) {
    if ($x) {
        return $x;
    }
    return 0;
}
PERL
    is scalar @$errs, 0, 'truthiness narrows Int|Undef to Int';
};

# ── Narrowing: isa ────────────────────────────

subtest 'narrowing: isa narrows to specific type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub foo :Type((Int | Str) -> Int) ($x) {
    if ($x isa Int) {
        return $x;
    }
    return 0;
}
PERL
    is scalar @$errs, 0, 'isa narrows to matched type';
};

# ── Narrowing: early return ───────────────────

subtest 'narrowing: return unless defined narrows scope' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub foo :Type((Int | Undef) -> Int) ($x) {
    return 0 unless defined $x;
    $x
}
PERL
    is scalar @$errs, 0, 'return unless defined narrows remaining scope';
};

# ── Narrowing: else-block inverse ─────────────

subtest 'narrowing: else block has inverse narrowing' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub foo :Type((Int | Undef) -> Undef) ($x) {
    if (defined $x) {
        return undef;
    } else {
        return $x;
    }
}
PERL
    is scalar @$errs, 0, 'else block narrows to Undef after defined guard';
};

done_testing;
