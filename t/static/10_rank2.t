use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;
use Typist::Static::Extractor;
use Typist::Parser;

# Helper: analyze source, return diagnostics of kind TypeMismatch
sub type_errors ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@* ];
}

# Helper: analyze source, return all diagnostics
sub all_diagnostics ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    $result->{diagnostics};
}

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
    my $diags = all_diagnostics(<<'PERL');
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

done_testing;
