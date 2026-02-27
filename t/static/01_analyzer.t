use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;
use Typist::Registry;

# ── Clean analysis ───────────────────────────────

subtest 'clean code produces no diagnostics' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package Clean;
use v5.40;

typedef Age => 'Int';

sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
    return $a + $b;
}
PERL

    is scalar @{$result->{diagnostics}}, 0, 'no diagnostics';
};

# ── Alias cycle detection ───────────────────────

subtest 'detects alias cycles' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
typedef Loop1 => 'Loop2';
typedef Loop2 => 'Loop1';
PERL

    ok scalar @{$result->{diagnostics}} > 0, 'has diagnostics';
    my @cycle = grep { $_->{kind} eq 'CycleError' } @{$result->{diagnostics}};
    ok @cycle, 'found cycle errors';
};

# ── Undeclared type variable ─────────────────────

subtest 'detects undeclared type variables' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub bad :Params(T) :Returns(T) ($x) { $x }
PERL

    my @undecl = grep { $_->{kind} eq 'UndeclaredTypeVar' } @{$result->{diagnostics}};
    ok @undecl, 'found undeclared type var errors';
};

subtest 'declared generics are clean' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub identity :Generic(T) :Params(T) :Returns(T) ($x) { $x }
PERL

    my @undecl = grep { $_->{kind} eq 'UndeclaredTypeVar' } @{$result->{diagnostics}};
    is scalar @undecl, 0, 'no undeclared type var errors';
};

# ── Unknown type alias ──────────────────────────

subtest 'detects unknown type aliases in functions' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub greet :Params(Username) :Returns(Str) ($name) { "Hi $name" }
PERL

    my @unknown = grep { $_->{kind} eq 'UnknownType' } @{$result->{diagnostics}};
    ok @unknown, 'found unknown type errors';
    like $unknown[0]->{message}, qr/Username/, 'mentions Username';
};

# ── Symbol index ─────────────────────────────────

subtest 'builds symbol index' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package SymTest;
use v5.40;

typedef Score => 'Int';
my $val :Type(Str);
sub calc :Params(Int) :Returns(Int) ($n) { $n * 2 }
PERL

    my @syms = @{$result->{symbols}};
    ok @syms >= 3, 'at least 3 symbols';

    my @kinds = sort map { $_->{kind} } @syms;
    ok((grep { $_ eq 'typedef' }  @kinds), 'has typedef symbol');
    ok((grep { $_ eq 'variable' } @kinds), 'has variable symbol');
    ok((grep { $_ eq 'function' } @kinds), 'has function symbol');
};

# ── Workspace registry integration ───────────────

subtest 'workspace registry provides cross-file aliases' => sub {
    my $ws = Typist::Registry->new;
    $ws->define_alias('UserId', 'Int');

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws);
use v5.40;
sub find_user :Params(UserId) :Returns(Str) ($id) { "user_$id" }
PERL

    my @unknown = grep { $_->{kind} eq 'UnknownType' } @{$result->{diagnostics}};
    is scalar @unknown, 0, 'UserId resolved via workspace registry';
};

# ── Diagnostic line enrichment ───────────────────

subtest 'diagnostics include line numbers' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', file => 'test.pm');
use v5.40;
typedef CycleA => 'CycleB';
typedef CycleB => 'CycleA';
PERL

    my @diags = @{$result->{diagnostics}};
    ok @diags, 'has diagnostics';
    ok $diags[0]->{line} > 0, 'diagnostic has nonzero line';
    is $diags[0]->{file}, 'test.pm', 'diagnostic has file';
};

# ── TypeClass superclass validation ────────────

subtest 'detects unknown superclass in typeclass' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', file => 'test.pm');
use v5.40;
typeclass Ord => 'T: NonExistent', +{
    compare => Func(T, T, returns => Int),
};
PERL

    my @unknown = grep { $_->{kind} eq 'UnknownTypeClass' } @{$result->{diagnostics}};
    ok @unknown, 'found UnknownTypeClass error';
    like $unknown[0]->{message}, qr/NonExistent/, 'mentions NonExistent';
};

subtest 'valid superclass produces no error' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
typeclass Eq => T, +{
    eq => Func(T, T, returns => Bool),
};
typeclass Ord => 'T: Eq', +{
    compare => Func(T, T, returns => Int),
};
PERL

    my @unknown = grep { $_->{kind} eq 'UnknownTypeClass' } @{$result->{diagnostics}};
    is scalar @unknown, 0, 'no UnknownTypeClass errors';
};

subtest 'detects superclass cycle' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', file => 'test.pm');
use v5.40;
typeclass CycleA => 'T: CycleB', +{};
typeclass CycleB => 'T: CycleA', +{};
PERL

    my @cycles = grep { $_->{kind} eq 'CycleError' } @{$result->{diagnostics}};
    ok @cycles, 'found CycleError for typeclass superclass cycle';
};

done_testing;
