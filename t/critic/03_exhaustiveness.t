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
        -include => ['Typist::ExhaustivenessCheck'],
        '-single-policy' => 'Typist::ExhaustivenessCheck',
    );
    $critic->critique(\$source);
}

# ── match with fallback — clean ──────────────────

subtest 'match with _ fallback has no violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
match $value,
    Some => sub ($v) { $v },
    None => sub { 0 },
    _    => sub { -1 };
PERL

    is scalar @violations, 0, 'no violations with fallback';
};

# ── match without fallback — violation ───────────

subtest 'match without _ fallback produces violation' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
match $value,
    Some => sub ($v) { $v },
    None => sub { 0 };
PERL

    is scalar @violations, 1, 'one violation';
    like $violations[0]->description,
        qr/match expression may not be exhaustive/,
        'violation message mentions exhaustiveness';
};

# ── No match calls — clean ───────────────────────

subtest 'code without match has no violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub add ($a, $b) { $a + $b }
PERL

    is scalar @violations, 0, 'no violations without match';
};

# ── Multiple match expressions ───────────────────

subtest 'multiple match expressions checked independently' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
match $x,
    A => sub { 1 },
    _ => sub { 0 };

match $y,
    B => sub { 2 },
    C => sub { 3 };
PERL

    is scalar @violations, 1, 'one violation (second match only)';
};

done_testing;
