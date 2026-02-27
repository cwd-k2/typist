use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Extractor;

# ── Package detection ────────────────────────────

subtest 'extracts package name' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package MyApp::User;
use v5.40;
PERL

    is $result->{package}, 'MyApp::User', 'package name extracted';
};

subtest 'defaults to main' => sub {
    my $result = Typist::Static::Extractor->extract('use v5.40;');
    is $result->{package}, 'main', 'default package is main';
};

# ── typedef extraction ──────────────────────────

subtest 'extracts typedef' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
typedef Age => 'Int';
typedef Name => 'Str';
PERL

    my $aliases = $result->{aliases};
    ok exists $aliases->{Age},  'Age typedef found';
    ok exists $aliases->{Name}, 'Name typedef found';
    is $aliases->{Age}{expr},  'Int', 'Age expr is Int';
    is $aliases->{Name}{expr}, 'Str', 'Name expr is Str';
    ok $aliases->{Age}{line} > 0, 'Age has line number';
};

# ── Variable extraction ─────────────────────────

subtest 'extracts typed variables' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
my $count :Type(Int) = 0;
my $name :Type(Str);
PERL

    my $vars = $result->{variables};
    is scalar @$vars, 2, 'found 2 typed variables';

    is $vars->[0]{name}, '$count', 'first var name';
    is $vars->[0]{type_expr}, 'Int', 'first var type';

    is $vars->[1]{name}, '$name', 'second var name';
    is $vars->[1]{type_expr}, 'Str', 'second var type';
};

subtest 'extracts parameterized types on variables' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
my $items :Type(ArrayRef[Int]) = [];
my $maybe :Type(Maybe[Str]);
PERL

    my $vars = $result->{variables};
    is $vars->[0]{type_expr}, 'ArrayRef[Int]', 'ArrayRef[Int] extracted';
    is $vars->[1]{type_expr}, 'Maybe[Str]',    'Maybe[Str] extracted';
};

# ── Function extraction ─────────────────────────

subtest 'extracts function annotations' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
    return $a + $b;
}
PERL

    my $fns = $result->{functions};
    ok exists $fns->{add}, 'add function found';

    my $add = $fns->{add};
    is_deeply $add->{params_expr}, ['Int', 'Int'], 'params extracted';
    is $add->{returns_expr}, 'Int', 'return type extracted';
    is_deeply $add->{generics}, [], 'no generics';
    ok $add->{line} > 0, 'has line number';
};

subtest 'extracts generic functions' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
sub first :Generic(T) :Params(ArrayRef[T]) :Returns(T) ($arr) {
    return $arr->[0];
}
PERL

    my $fn = $result->{functions}{first};
    ok $fn, 'first function found';
    is_deeply $fn->{generics}, ['T'], 'generic T declared';
    is_deeply $fn->{params_expr}, ['ArrayRef[T]'], 'param with type var';
    is $fn->{returns_expr}, 'T', 'returns type var';
};

subtest 'ignores subs without type annotations' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
sub helper ($x) { $x + 1 }
PERL

    is scalar keys $result->{functions}->%*, 0, 'no functions extracted';
};

# ── Combined extraction ──────────────────────────

subtest 'full file extraction' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package MyLib;
use v5.40;

typedef Email => 'Str';

my $count :Type(Int) = 0;

sub greet :Params(Str) :Returns(Str) ($name) {
    return "Hello, $name!";
}
PERL

    is $result->{package}, 'MyLib', 'package';
    ok exists $result->{aliases}{Email}, 'typedef found';
    is scalar @{$result->{variables}}, 1, '1 variable';
    ok exists $result->{functions}{greet}, 'function found';
};

done_testing;
