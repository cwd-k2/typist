use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::Analyze qw(type_errors all_errors);
use Typist::Static::Extractor;
use Typist::Parser;

# ── Parser integration (via parse_annotation) ──

subtest 'parse_annotation: rank-2 parameter type' => sub {
    my $ann = Typist::Parser->parse_annotation('(forall A. A -> A, Int) -> Int');
    ok $ann->{type}->is_func, 'outer is Func';
    my @params = $ann->{type}->params;
    ok $params[0]->is_quantified, 'first param is Quantified';
    ok $params[1]->is_atom, 'second param is Int';
};

subtest 'parse_annotation: forall with generics' => sub {
    my $ann = Typist::Parser->parse_annotation('<T>(forall A. A -> A, T) -> T');
    ok $ann->{type}->is_func, 'outer is Func';
    my @params = $ann->{type}->params;
    ok $params[0]->is_quantified, 'first param is Quantified';
    is_deeply $ann->{generics_raw}, ['T'], 'generic T extracted';
};

# ── Extractor: forall in :sig() annotations ──

subtest 'Extractor: rank-2 function extraction' => sub {
    my $source = <<'PERL';
use v5.40;
sub apply_twice :sig((forall A. A -> A, Int) -> Int) ($f, $x) {
    $f->($f->($x));
}
PERL

    my $extracted = Typist::Static::Extractor->extract($source);
    my $fn = $extracted->{functions}{apply_twice};
    ok $fn, 'apply_twice extracted';
    is scalar $fn->{params_expr}->@*, 2, 'two params';
    like $fn->{params_expr}[0], qr/forall/, 'first param contains forall';
    is $fn->{returns_expr}, 'Int', 'returns Int';
};

# ── TypeChecker: rank-2 argument checking ──────

subtest 'TypeChecker: rank-2 param accepts quantified-subtype argument' => sub {
    # This tests that the extracted function can be analyzed without errors.
    # The type checker won't have a quantified argument to check against
    # unless we can infer it, so we primarily verify no crashes.
    my $diags = all_errors(<<'PERL');
use v5.40;
sub apply_twice :sig((forall A. A -> A, Int) -> Int) ($f, $x) {
    42;
}
PERL

    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @$diags;
    is scalar @type_errs, 0, 'no type errors for rank-2 function definition';
};

subtest 'TypeChecker: rank-2 function return type check' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub apply_twice :sig((forall A. A -> A, Int) -> Int) ($f, $x) {
    return "hello";
}
PERL

    is scalar @$errs, 1, 'one type mismatch';
    like $errs->[0]{message}, qr/return.*apply_twice.*Int/i, 'return type mismatch detected';
};

# ── Subtype checks through static analysis ──

subtest 'Subtype: forall roundtrip through Parser' => sub {
    my $q = Typist::Parser->parse('forall A. A -> A');
    my $str = $q->to_string;
    my $q2 = Typist::Parser->parse($str);
    ok $q2->is_quantified, 'roundtrip preserves Quantified';
    is $q2->to_string, $str, 'roundtrip string is identical';
};

subtest 'Subtype: forall A. (A, A) -> A roundtrip' => sub {
    my $q = Typist::Parser->parse('forall A. (A, A) -> A');
    my $str = $q->to_string;
    my $q2 = Typist::Parser->parse($str);
    ok $q2->is_quantified, 'roundtrip preserves Quantified';
    ok $q2->body->is_func, 'body is Func';
    is scalar($q2->body->params), 2, 'body has two params';
};

# ── Codensity pattern: Rank-2 + HKT ──────────

subtest 'Codensity: lift_list → lower_list chain no TypeMismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;

sub lift_list :sig(<A>(ArrayRef[A]) -> forall R. (A -> ArrayRef[R]) -> ArrayRef[R]) ($arr) {
    sub ($k) { [map { $k->($_)->@* } @$arr] };
}

sub lower_list :sig(<A>(forall R. (A -> ArrayRef[R]) -> ArrayRef[R]) -> ArrayRef[A]) ($m) {
    $m->(sub ($a) { [$a] });
}

my $xs   = lift_list([1, 2, 3]);
my $list = lower_list($xs);
PERL

    is scalar @$errs, 0, 'no TypeMismatch for lift_list → lower_list';
};

subtest 'Codensity: bind chain no TypeMismatch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;

sub c_unit :sig(<A>(A) -> forall R. (A -> ArrayRef[R]) -> ArrayRef[R]) ($a) {
    sub ($k) { $k->($a) };
}

sub c_bind :sig(<A, B>(forall R. (A -> ArrayRef[R]) -> ArrayRef[R], (A) -> forall R. (B -> ArrayRef[R]) -> ArrayRef[R]) -> forall R. (B -> ArrayRef[R]) -> ArrayRef[R]) ($m, $f) {
    sub ($k) { $m->(sub ($a) { $f->($a)->($k) }) };
}

sub lift_list :sig(<A>(ArrayRef[A]) -> forall R. (A -> ArrayRef[R]) -> ArrayRef[R]) ($arr) {
    sub ($k) { [map { $k->($_)->@* } @$arr] };
}

sub lower_list :sig(<A>(forall R. (A -> ArrayRef[R]) -> ArrayRef[R]) -> ArrayRef[A]) ($m) {
    $m->(sub ($a) { [$a] });
}

my $xs = lift_list(["a", "b"]);
my $ys = lift_list([1, 2]);
my $combined = c_bind($xs, sub ($x) {
    c_bind($ys, sub ($y) {
        c_unit($x);
    });
});
my $result = lower_list($combined);
PERL

    is scalar @$errs, 0, 'no TypeMismatch for bind chain with Codensity';
};

done_testing;
