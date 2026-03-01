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
        -include => ['Typist::AnnotationStyle'],
        '-single-policy' => 'Typist::AnnotationStyle',
    );
    $critic->critique(\$source);
}

# ── Annotated public sub — clean ─────────────────

subtest 'annotated public sub has no violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Str) ($name) { "Hello $name" }
PERL

    is scalar @violations, 0, 'no violations';
};

# ── Private sub without annotation — clean ───────

subtest 'private sub without annotation has no violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub _helper ($x) { $x + 1 }
PERL

    is scalar @violations, 0, 'no violations for private sub';
};

# ── Public sub without annotation — violation ────

subtest 'public sub without annotation produces violation' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub greet ($name) { "Hello $name" }
PERL

    is scalar @violations, 1, 'one violation';
    like $violations[0]->description, qr/Public sub 'greet' lacks :Type\(\) annotation/,
        'violation message mentions missing annotation';
};

# ── Multiple subs — mixed ────────────────────────

subtest 'mixed subs: only unannotated public flagged' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
sub mul ($a, $b) { $a * $b }
sub _internal ($x) { $x }
sub div ($a, $b) { $a / $b }
PERL

    is scalar @violations, 2, 'two violations (mul and div)';
    ok((grep { $_->description =~ /mul/ } @violations), 'mul flagged');
    ok((grep { $_->description =~ /div/ } @violations), 'div flagged');
};

done_testing;
