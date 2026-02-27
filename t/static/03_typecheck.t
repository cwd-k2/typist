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
    like $errs->[0]{message}, qr/\$x.*Int.*Str/, 'message mentions Int and Str';
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
    like $errs->[0]{message}, qr/Return.*greet.*Int.*Str/, 'return type mismatch';
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

done_testing;
