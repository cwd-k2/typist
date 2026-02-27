use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;

# Helper: analyze source, return diagnostics of kind TypeMismatch
sub type_errors ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@* ];
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
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
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
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
    return $a + $b;
}
add(3, 4);
PERL

    is scalar @$errs, 0, 'no errors';
};

subtest 'call: subtype arg is allowed' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub process :Params(Num) :Returns(Num) ($x) {
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
sub greet :Params(Str) :Returns(Int) ($name) {
    return "hello";
}
PERL

    is scalar @$errs, 1, 'one error';
    like $errs->[0]{message}, qr/Return.*greet.*Int/, 'return type mismatch';
};

subtest 'return: no error on matching type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub double :Params(Int) :Returns(Int) ($x) {
    return 42;
}
PERL

    is scalar @$errs, 0, 'no errors';
};

subtest 'return: no :Returns → skip' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub foo :Params(Int) ($x) {
    return "anything";
}
PERL

    is scalar @$errs, 0, 'no errors without :Returns';
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

subtest 'skip: generic function call' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub first :Generic(T) :Params(ArrayRef[T]) :Returns(T) ($arr) {
    return $arr->[0];
}
first("hello");
PERL

    is scalar @$errs, 0, 'skip generic function calls';
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
sub greet :Params(Str) :Returns(Str) ($name) {
    return "hello $name";
}
my $x :Type(Str) = greet("world");
PERL

    is scalar @$errs, 0, 'greet() returns Str, assigned to Str — no error';
};

subtest 'call: detects return-type vs variable-type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Params(Str) :Returns(Str) ($name) {
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
sub greet :Params(Str) :Returns(Str) ($name) {
    return "hello $name";
}
sub loud :Params(Str) :Returns(Str) ($s) {
    return $s;
}
loud(greet("world"));
PERL

    is scalar @$errs, 0, 'greet() returns Str, loud() accepts Str — no error';
};

subtest 'call: nested call type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Params(Str) :Returns(Str) ($name) {
    return "hello $name";
}
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
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
sub double :Params(Int) :Returns(Int) ($x) {
    return $x * 2;
}
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
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
sub loud :Params(Str) :Returns(Str) ($s) {
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
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
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
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
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
sub process :Params(Int) :Returns(Int) ($n) {
    return $n;
}
process(make_thing(42));
PERL

    is scalar @$errs, 0, 'unannotated function as arg → skip check';
};

subtest 'skip: partially annotated function (Params only, no Returns)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub compute :Params(Int) ($n) {
    return $n * 2;
}
my $x :Type(Int) = compute(42);
PERL

    is scalar @$errs, 0, 'Params-only function → return type unknown, skip';
};

# ── Flow Typing (unannotated variable inference) ─

subtest 'flow: inferred variable from function call' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Params(Str) :Returns(Str) ($name) {
    return "hello $name";
}
sub loud :Params(Str) :Returns(Str) ($s) {
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
sub greet :Params(Str) :Returns(Str) ($name) {
    return "hello $name";
}
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
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
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
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
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
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
sub greet :Params(Str) :Returns(Str) ($name) {
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
sub greet :Params(Str) :Returns(Str) ($name) {
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
    is $fn->{eff_expr}, '*', 'unannotated function shows eff_expr = *';
};

# ── Function Parameter Typing ─────────────────

subtest 'return: param type enables return type mismatch detection' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :Params(Str) :Returns(Int) ($name) {
    return $name;
}
PERL

    is scalar @$errs, 1, 'one error: returning Str param as Int';
    like $errs->[0]{message}, qr/Return.*greet.*Int.*Str/, 'detects Str vs Int mismatch';
};

subtest 'return: param type matches return type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub identity :Params(Int) :Returns(Int) ($x) {
    return $x;
}
PERL

    is scalar @$errs, 0, 'no error: returning Int param as Int';
};

subtest 'call: param type used in inner call site check' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
    return $a + $b;
}
sub wrong :Params(Str) :Returns(Int) ($s) {
    return add($s, 1);
}
PERL

    is scalar @$errs, 1, 'one error: Str param passed to Int arg';
    like $errs->[0]{message}, qr/Argument 1.*add.*Int.*Str/, 'detects param type mismatch at inner call';
};

done_testing;
