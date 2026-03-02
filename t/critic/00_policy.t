use v5.40;
use Test::More;
use lib 'lib';

# Check if Perl::Critic is available
BEGIN {
    eval { require Perl::Critic; Perl::Critic->import() };
    if ($@) {
        require Test::More;
        Test::More::plan(skip_all => 'Perl::Critic not installed');
    }
}

# ── Helper ───────────────────────────────────────

sub critique_source ($source) {
    my $critic = Perl::Critic->new(
        -only    => 1,
        -include => ['Typist::TypeCheck'],
        '-single-policy' => 'Typist::TypeCheck',
    );
    $critic->critique(\$source);
}

# ── Clean code ───────────────────────────────────

subtest 'clean code has no violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
typedef Age => 'Int';
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
PERL

    is scalar @violations, 0, 'no violations';
};

# ── Cycle detection ──────────────────────────────

subtest 'alias cycle produces violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
typedef Loop1 => 'Loop2';
typedef Loop2 => 'Loop1';
PERL

    ok scalar @violations > 0, 'has violations';
    ok((grep { $_->description =~ /CycleError/ } @violations), 'cycle error found');
};

# ── Undeclared type variable ─────────────────────

subtest 'undeclared type var produces violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub bad :sig((T) -> T) ($x) { $x }
PERL

    ok scalar @violations > 0, 'has violations';
    ok((grep { $_->description =~ /UndeclaredTypeVar/ } @violations), 'undeclared type var found');
};

# ── Unknown type alias ──────────────────────────

subtest 'unknown type alias produces violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub greet :sig((Username) -> Str) ($n) { "Hi $n" }
PERL

    ok scalar @violations > 0, 'has violations';
    ok((grep { $_->description =~ /UnknownType/ } @violations), 'unknown type found');
};

# ── Declared generic is clean ────────────────────

subtest 'declared generic produces no violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub identity :sig(<T>(T) -> T) ($x) { $x }
PERL

    is scalar @violations, 0, 'no violations for declared generic';
};

done_testing;
