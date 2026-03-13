use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::Analyze qw(type_errors);

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

# ── Widening after branch exit ──────────────────

subtest 'defined narrowing does not leak past branch end' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($x) { }
sub check :sig((Maybe[Str]) -> Void) ($x) {
    if (defined($x)) {
        takes_str($x);
    }
    takes_str($x);
}
PERL

    is scalar @$errs, 1, 'one error after branch exit';
    like $errs->[0]{message}, qr/Argument 1.*takes_str.*Str/, 'value is widened again after leaving the branch';
};

subtest 'unless else branch narrowing does not leak into following flat scope' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($x) { }
sub check :sig((Maybe[Str]) -> Void) ($x) {
    unless (defined($x)) {
        return;
    } else {
        takes_str($x);
    }
    takes_str($x);
}
PERL

    is scalar @$errs, 0, 'early return preserves narrowing in following flat scope';
};

# ── Early return flat-scope behavior ────────────

subtest 'early return narrowing applies after nested branch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Str) ($x) { $x }
sub check :sig((Maybe[Str], Bool) -> Str) ($x, $flag) {
    return "none" unless defined $x;
    if ($flag) {
        my $y :sig(Str) = $x;
    }
    return takes_str($x);
}
PERL

    is scalar @$errs, 0, 'early return narrowing survives through later flat scope';
};

subtest 'branch-local narrowing does not survive sibling branch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($x) { }
sub check :sig((Maybe[Str], Bool) -> Void) ($x, $flag) {
    if (defined($x)) {
        takes_str($x);
    }
    if ($flag) {
        return;
    }
    takes_str($x);
}
PERL

    is scalar @$errs, 1, 'one error after sibling branch merge';
    like $errs->[0]{message}, qr/Argument 1.*takes_str.*Str/, 'branch-local narrowing is widened at merge point';
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

# ── Ternary defined() narrowing ───────────────────

subtest 'ternary: defined($s) narrows in then-branch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub safe_len :sig((Str | Undef) -> Int) ($s) {
    return defined($s) ? length($s) : 0;
}
PERL

    is scalar @$errs, 0, 'defined($s) ? length($s) : 0 — no false positive';
};

subtest 'ternary: defined($s) else-branch keeps Union' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Str | Undef) -> Str) ($s) {
    return defined($s) ? $s : "default";
}
PERL

    is scalar @$errs, 0, 'defined($s) ? $s : "default" — $s narrowed to Str in then';
};

# ── Implicit return inside narrowed block ─────────

subtest 'implicit return inside if-defined block' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Str | Undef) -> Str) ($s) {
    if (defined($s)) {
        $s;
    } else {
        "default";
    }
}
PERL

    is scalar @$errs, 0, 'implicit return in if-defined block: $s narrowed to Str';
};

# ── Postfix if defined narrowing for return ──────

subtest 'postfix if defined narrows return value' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub test :sig((Str | Undef) -> Str) ($s) {
    return $s if defined($s);
    return "default";
}
PERL

    is scalar @$errs, 0, 'return $s if defined($s) — no false positive';
};

# ── Nested block narrowing ───────────────────────

subtest 'nested if preserves outer defined narrowing' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($s) { }
sub check :sig((Str | Undef, Bool) -> Void) ($s, $flag) {
    if (defined($s)) {
        if ($flag) {
            takes_str($s);
        }
    }
}
PERL

    is scalar @$errs, 0, 'outer defined() narrowing preserved in nested block';
};

# ── Negated defined guard ────────────────────────

subtest 'if (!defined) guard narrows after return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($s) { }
sub check :sig((Str | Undef) -> Void) ($s) {
    if (!defined($s)) {
        return;
    }
    takes_str($s);
}
PERL

    is scalar @$errs, 0, 'if (!defined($s)) { return } narrows $s after guard';
};

# ── die/croak as diverging guard ─────────────────

subtest 'die unless defined narrows remaining scope' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($s) { }
sub check :sig((Str | Undef) -> Void) ($s) {
    die "missing" unless defined($s);
    takes_str($s);
}
PERL

    is scalar @$errs, 0, 'die unless defined($s) narrows $s after guard';
};

# ── elsif condition narrowing ─────────────────────

subtest 'elsif defined narrows in elsif block' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($s) { }
sub check :sig((Str | Undef, Bool) -> Void) ($s, $flag) {
    if ($flag) {
        return;
    } elsif (defined($s)) {
        takes_str($s);
    }
}
PERL

    is scalar @$errs, 0, 'elsif (defined($s)) narrows $s in elsif block';
};

# ── Compound && condition narrowing ───────────────

subtest 'defined($x) && defined($y) narrows both' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($s) { }
sub takes_int :sig((Int) -> Void) ($n) { }
sub check :sig((Str | Undef, Int | Undef) -> Void) ($s, $n) {
    if (defined($s) && defined($n)) {
        takes_str($s);
        takes_int($n);
    }
}
PERL

    is scalar @$errs, 0, 'both variables narrowed with && compound condition';
};

# ── Ternary else-branch must NOT narrow ──────────

subtest 'ternary else-branch does not narrow defined' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($s) { }
sub check :sig((Str | Undef) -> Void) ($s) {
    defined($s) ? takes_str($s) : takes_str($s);
}
PERL

    is scalar @$errs, 1, 'one error in else-branch of ternary';
    like $errs->[0]{message}, qr/Argument 1/, 'else-branch $s is still Str | Undef';
};

# ── Short-circuit guard: defined($s) || return ───

subtest 'defined($s) or die narrows remaining scope' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($s) { }
sub check :sig((Str | Undef) -> Void) ($s) {
    defined($s) or die "missing";
    takes_str($s);
}
PERL

    is scalar @$errs, 0, 'defined($s) or die narrows $s after guard';
};

subtest 'defined($s) || return narrows remaining scope' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($s) { }
sub check :sig((Str | Undef) -> Str) ($s) {
    defined($s) || return "default";
    takes_str($s);
    $s;
}
PERL

    is scalar @$errs, 0, 'defined($s) || return narrows $s after guard';
};

# ── Ternary defined accessor narrowing ───────────

subtest 'ternary defined accessor narrows in then-branch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Widget => (optional(tip => 'Str'));
sub get_tip :sig((Widget) -> Str) ($w) {
    return defined($w->tip) ? $w->tip : "none";
}
PERL

    is scalar @$errs, 0, 'defined($w->tip) ? $w->tip : "none" — no false positive';
};

# ── Ternary as function argument ─────────────────

subtest 'ternary defined in function argument position' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub takes_str :sig((Str) -> Void) ($s) { }
sub check :sig((Str | Undef) -> Void) ($s) {
    takes_str(defined($s) ? $s : "default");
}
PERL

    is scalar @$errs, 0, 'takes_str(defined($s) ? $s : "default") — no false positive';
};

done_testing;
