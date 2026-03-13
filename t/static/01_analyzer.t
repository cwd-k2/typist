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

sub add :sig((Int, Int) -> Int) ($a, $b) {
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
sub bad :sig((T) -> T) ($x) { $x }
PERL

    my @undecl = grep { $_->{kind} eq 'UndeclaredTypeVar' } @{$result->{diagnostics}};
    ok @undecl, 'found undeclared type var errors';
};

subtest 'declared generics are clean' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub identity :sig(<T>(T) -> T) ($x) { $x }
PERL

    my @undecl = grep { $_->{kind} eq 'UndeclaredTypeVar' } @{$result->{diagnostics}};
    is scalar @undecl, 0, 'no undeclared type var errors';
};

# ── Unknown type alias ──────────────────────────

subtest 'detects unknown type aliases in functions' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
use v5.40;
sub greet :sig((Username) -> Str) ($name) { "Hi $name" }
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
my $val :sig(Str);
sub calc :sig((Int) -> Int) ($n) { $n * 2 }
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
sub find_user :sig((UserId) -> Str) ($id) { "user_$id" }
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
    compare => '(T, T) -> Int',
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
    eq => '(T, T) -> Bool',
};
typeclass Ord => 'T: Eq', +{
    compare => '(T, T) -> Int',
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

# ── Source map precision ─────────────────────────

subtest 'diagnostics have precise line numbers from Checker' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', file => 'precise.pm');
use v5.40;

typedef GoodAlias => 'Int';

typedef BadCycle1 => 'BadCycle2';
typedef BadCycle2 => 'BadCycle1';

sub undecl :sig((T) -> T) ($x) { $x }

sub unknown :sig((MissingType) -> Str) ($x) { "hi" }
PERL

    my @diags = @{$result->{diagnostics}};

    # Alias cycle: should point to the typedef lines (5 or 6)
    my @cycles = grep { $_->{kind} eq 'CycleError' } @diags;
    ok @cycles, 'has cycle diagnostics';
    for my $c (@cycles) {
        is $c->{file}, 'precise.pm', 'cycle diagnostic has correct file';
        ok $c->{line} == 5 || $c->{line} == 6, "cycle diagnostic line ($c->{line}) points to typedef";
    }

    # Undeclared type variable: should point to the sub line (8)
    my @undecl = grep { $_->{kind} eq 'UndeclaredTypeVar' } @diags;
    ok @undecl, 'has undeclared type var diagnostic';
    is $undecl[0]->{file}, 'precise.pm', 'undecl diagnostic has correct file';
    is $undecl[0]->{line}, 8, 'undecl diagnostic points to sub declaration line';

    # Unknown type: should point to the sub line (10)
    my @unknown = grep { $_->{kind} eq 'UnknownType' } @diags;
    ok @unknown, 'has unknown type diagnostic';
    is $unknown[0]->{file}, 'precise.pm', 'unknown type diagnostic has correct file';
    is $unknown[0]->{line}, 10, 'unknown type diagnostic points to sub declaration line';
};

subtest 'typeclass diagnostics have precise line numbers' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', file => 'tc.pm');
use v5.40;

typeclass Show => T, +{};

typeclass BadOrd => 'T: NoSuchClass', +{
    compare => '(T, T) -> Int',
};
PERL

    my @diags = @{$result->{diagnostics}};

    my @unknown_tc = grep { $_->{kind} eq 'UnknownTypeClass' } @diags;
    ok @unknown_tc, 'has unknown typeclass diagnostic';
    is $unknown_tc[0]->{file}, 'tc.pm', 'typeclass diagnostic has correct file';
    is $unknown_tc[0]->{line}, 5, 'typeclass diagnostic points to typeclass definition line';
};

# ── Structured CycleError dispatch ─────────────

subtest 'alias cycle produces structured CycleError in registry' => sub {
    my $r = Typist::Registry->new;
    $r->define_alias('Foo', 'Bar');
    $r->define_alias('Bar', 'Foo');

    eval { $r->lookup_type('Foo') };
    my $err = $@;
    ok $err, 'lookup_type dies on cycle';
    is ref $err, 'HASH', 'exception is a hashref (structured)';
    is $err->{type}, 'CycleError', 'exception type is CycleError';
    is $err->{name}, 'Foo', 'exception carries the alias name';
};

subtest 'TypeEnv survives alias cycle without crashing' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', file => 'cycle_env.pm');
use v5.40;
typedef CycA => 'CycB';
typedef CycB => 'CycA';

sub use_cycle :sig((CycA) -> CycA) ($x) { $x }
PERL

    my @cycles = grep { $_->{kind} eq 'CycleError' } @{$result->{diagnostics}};
    ok @cycles, 'cycle errors detected';
    # Key: the analyzer completes without crashing despite env building
    ok defined $result->{diagnostics}, 'analyzer completed successfully';
};

done_testing;
