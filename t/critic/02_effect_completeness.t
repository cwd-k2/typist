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
        -include => ['Typist::EffectCompleteness'],
        '-single-policy' => 'Typist::EffectCompleteness',
    );
    $critic->critique(\$source);
}

# ── Properly declared effects — clean ────────────

subtest 'sub with declared effect has no violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Void !Eff(Console)) ($name) {
    Console::writeLine("Hello $name");
}
PERL

    is scalar @violations, 0, 'no violations when effect declared';
};

# ── No effect calls — clean ──────────────────────

subtest 'pure sub has no violations' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
PERL

    is scalar @violations, 0, 'no violations for pure sub';
};

# ── Effect call without declaration — violation ──

subtest 'sub calling effect op without declaration produces violation' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub greet :Type((Str) -> Void) ($name) {
    Console::writeLine("Hello $name");
}
PERL

    is scalar @violations, 1, 'one violation';
    like $violations[0]->description,
        qr/calls effect operations without declaring effects/,
        'violation message is correct';
};

# ── No annotation at all but calls effect — violation ──

subtest 'unannotated sub calling effect op produces violation' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub greet ($name) {
    Console::writeLine("Hello $name");
}
PERL

    is scalar @violations, 1, 'one violation';
    like $violations[0]->description,
        qr/calls effect operations/,
        'violation message mentions effect operations';
};

# ── Well-known non-effect packages — clean ───────

subtest 'calls to well-known packages are not flagged' => sub {
    my @violations = critique_source(<<'PERL');
use v5.40;
sub helper :Type((Str) -> Str) ($x) {
    Test::ok(1);
    Carp::croak("fail");
    return $x;
}
PERL

    is scalar @violations, 0, 'no violations for well-known packages';
};

done_testing;
