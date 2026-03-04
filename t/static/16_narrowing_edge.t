use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;

sub type_errors ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@* ];
}

sub all_errors ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    $result->{diagnostics};
}

# ── Nested defined check ───────────────────────

subtest 'nested defined narrows Maybe to concrete' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Str]) -> Void) ($x) {
    if (defined($x)) {
        my $s :sig(Str) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'defined narrows Maybe[Str] to Str';
};

# ── unless (negation) narrowing ────────────────

subtest 'unless reverses narrowing polarity' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Int]) -> Void) ($x) {
    unless (defined($x)) {
        my $u :sig(Undef) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'unless defined narrows to Undef';
};

# ── Early return narrowing ─────────────────────

subtest 'early return narrows remaining scope' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub process :sig((Maybe[Str]) -> Str) ($name) {
    return "none" unless defined $name;
    my $result :sig(Str) = $name;
    $result;
}
PERL

    is scalar @$errs, 0, 'early return narrows Maybe[Str] to Str';
};

# ── isa narrowing ──────────────────────────────

subtest 'isa narrows to specific type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if ($x isa Typist::Type::Atom) {
        my $a :sig(Typist::Type::Atom) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'isa narrows Any to specific class';
};

# ── Truthiness narrowing ──────────────────────

subtest 'truthiness narrows Maybe to concrete' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Maybe[Str]) -> Void) ($x) {
    if ($x) {
        my $s :sig(Str) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'truthiness narrows Maybe[Str] to Str';
};

# ── NarrowingEngine unit tests ─────────────────

subtest 'remove_undef_from_type' => sub {
    require Typist::Static::NarrowingEngine;
    require Typist::Type::Union;
    require Typist::Type::Atom;

    my $engine = Typist::Static::NarrowingEngine->new();

    # Maybe[Str] = Str | Undef → Str
    my $maybe_str = Typist::Type::Union->new(
        Typist::Type::Atom->new('Str'),
        Typist::Type::Atom->new('Undef'),
    );
    my $narrowed = $engine->remove_undef_from_type($maybe_str);
    ok $narrowed, 'Undef removed from union';
    is $narrowed->to_string, 'Str', 'narrowed to Str';

    # Int | Str | Undef → Int | Str
    my $three_way = Typist::Type::Union->new(
        Typist::Type::Atom->new('Int'),
        Typist::Type::Atom->new('Str'),
        Typist::Type::Atom->new('Undef'),
    );
    my $narrowed2 = $engine->remove_undef_from_type($three_way);
    ok $narrowed2, 'Undef removed from 3-way union';
    ok $narrowed2->is_union, 'result is still a union';
    is scalar($narrowed2->members), 2, 'two members remain';

    # Int (not a union) → undef (no change)
    my $int = Typist::Type::Atom->new('Int');
    my $no_change = $engine->remove_undef_from_type($int);
    ok !defined $no_change, 'non-union returns undef';

    # Str | Int (no Undef) → undef (no change)
    my $no_undef = Typist::Type::Union->new(
        Typist::Type::Atom->new('Str'),
        Typist::Type::Atom->new('Int'),
    );
    my $no_change2 = $engine->remove_undef_from_type($no_undef);
    ok !defined $no_change2, 'union without Undef returns undef';
};

done_testing;
