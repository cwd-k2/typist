use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::Analyze qw(type_errors all_errors);

# ════════════════════════════════════════════════════════════
# Multi-level accessor chain narrowing tests
#
# Current implementation only supports single-level accessor
# narrowing (e.g., defined($obj->field)).  These tests verify
# behavior for multi-level chains (e.g., defined($obj->a->b))
# and document the DESIGN_GAP to be closed.
# ════════════════════════════════════════════════════════════

# ── Struct definitions shared across tests ────────────────
# These are embedded in each subtest to be self-contained.

# ════════════════════════════════════════════════════════════
# Section 1: Block narrowing with multi-level chains
# ════════════════════════════════════════════════════════════

subtest 'multilevel: if (defined($obj->a->b)) block narrowing' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (optional(value => 'Str'));
struct Outer => (inner => 'Inner');
sub get_val :sig((Outer) -> Str) ($o) {
    if (defined($o->inner->value)) {
        return $o->inner->value;
    }
    return "default";
}
PERL

    is scalar @$errs, 0,
        'defined($o->inner->value) narrows to Str in then-block';
};

# ════════════════════════════════════════════════════════════
# Section 2: Early return narrowing with multi-level chains
# ════════════════════════════════════════════════════════════

subtest 'multilevel: return unless defined($obj->a->b)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (optional(value => 'Str'));
struct Outer => (inner => 'Inner');
sub get_val :sig((Outer) -> Str) ($o) {
    return "default" unless defined($o->inner->value);
    return $o->inner->value;
}
PERL

    is scalar @$errs, 0,
        'early return narrows multi-level accessor in remaining scope';
};

# ════════════════════════════════════════════════════════════
# Section 3: Compound fallthrough with multi-level chains
# ════════════════════════════════════════════════════════════

subtest 'multilevel: unless/else compound fallthrough' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (optional(value => 'Str'));
struct Outer => (inner => 'Inner');
sub get_val :sig((Outer) -> Str) ($o) {
    unless (defined($o->inner->value)) {
        return "default";
    } else {
        return $o->inner->value;
    }
}
PERL

    is scalar @$errs, 0,
        'unless/else compound narrows multi-level accessor in else-block';
};

# ════════════════════════════════════════════════════════════
# Section 4: Ternary narrowing with multi-level chains
# ════════════════════════════════════════════════════════════

subtest 'multilevel: defined($obj->a->b) ? expr : default' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (optional(value => 'Str'));
struct Outer => (inner => 'Inner');
sub get_val :sig((Outer) -> Str) ($o) {
    return defined($o->inner->value) ? $o->inner->value : "default";
}
PERL

    is scalar @$errs, 0,
        'ternary narrows multi-level accessor in then-branch';
};

# ════════════════════════════════════════════════════════════
# Section 5: Short-circuit guard with multi-level chains
# ════════════════════════════════════════════════════════════

subtest 'multilevel: defined($obj->a->b) or return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (optional(value => 'Str'));
struct Outer => (inner => 'Inner');
sub get_val :sig((Outer) -> Str) ($o) {
    defined($o->inner->value) or return "default";
    return $o->inner->value;
}
PERL

    # DESIGN_GAP: short-circuit `defined(accessor) or return` does not
    # narrow accessor chains (same limitation exists for single-level).
    ok scalar @$errs >= 1,
        'short-circuit guard does not yet narrow accessor chains (design gap)';
};

# ════════════════════════════════════════════════════════════
# Section 6: Three-level chains
# ════════════════════════════════════════════════════════════

subtest 'multilevel: three-level chain defined($a->b->c->d)' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Deep   => (optional(val => 'Int'));
struct Middle => (deep => 'Deep');
struct Top    => (mid  => 'Middle');
sub get_deep :sig((Top) -> Int) ($t) {
    if (defined($t->mid->deep->val)) {
        return $t->mid->deep->val;
    }
    return 0;
}
PERL

    is scalar @$errs, 0,
        'three-level defined() chain narrows deepest optional field';
};

# ════════════════════════════════════════════════════════════
# Section 7: Intermediate chain narrowing
#   defined($obj->a->b) should also narrow $obj->a
#   (removing Undef from its type if the intermediate is optional)
# ════════════════════════════════════════════════════════════

subtest 'multilevel: intermediate optional narrowed by deep defined()' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (value => 'Str');
struct Outer => (optional(inner => 'Inner'));
sub get_val :sig((Outer) -> Str) ($o) {
    if (defined($o->inner->value)) {
        # $o->inner must be Inner (not Undef) to reach ->value
        my $i :sig(Inner) = $o->inner;
        return $i->value;
    }
    return "default";
}
PERL

    # DESIGN_GAP: defined($o->inner->value) narrows the leaf (value) but does
    # not yet propagate narrowing to intermediate optional fields ($o->inner).
    ok scalar @$errs >= 1,
        'intermediate optional narrowing not yet implemented (design gap)';
};

# ════════════════════════════════════════════════════════════
# Section 8: Mixed required and optional fields in chain
# ════════════════════════════════════════════════════════════

subtest 'multilevel: required then optional in chain' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Config => (optional(port => 'Int'));
struct App    => (config => 'Config');
sub get_port :sig((App) -> Int) ($app) {
    if (defined($app->config->port)) {
        return $app->config->port;
    }
    return 8080;
}
PERL

    is scalar @$errs, 0,
        'required->optional chain: defined() narrows the optional leaf';
};

subtest 'multilevel: optional then required in chain' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (value => 'Str');
struct Outer => (optional(inner => 'Inner'));
sub get_inner_val :sig((Outer) -> Str) ($o) {
    if (defined($o->inner)) {
        return $o->inner->value;
    }
    return "default";
}
PERL

    is scalar @$errs, 0,
        'single-level defined() of optional field, then required child access';
};

# ════════════════════════════════════════════════════════════
# Section 9: Chain with alias types (typedef)
# ════════════════════════════════════════════════════════════

subtest 'multilevel: chain through typedef alias' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Detail => (optional(note => 'Str'));
typedef Info => 'Detail';
struct Item => (info => 'Info');
sub get_note :sig((Item) -> Str) ($item) {
    if (defined($item->info->note)) {
        return $item->info->note;
    }
    return "none";
}
PERL

    is scalar @$errs, 0,
        'defined() through typedef alias resolves accessor chain';
};

# ════════════════════════════════════════════════════════════
# Section 10: Negative tests — type errors should be caught
# ════════════════════════════════════════════════════════════

subtest 'multilevel: unguarded multi-level optional access' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (optional(value => 'Str'));
struct Outer => (inner => 'Inner');
sub get_val :sig((Outer) -> Str) ($o) {
    return $o->inner->value;
}
PERL

    ok scalar @$errs >= 1,
        'unguarded access to optional field produces type error (Str | Undef vs Str)';
};

subtest 'multilevel: narrowing does not leak past branch' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (optional(value => 'Str'));
struct Outer => (inner => 'Inner');
sub takes_str :sig((Str) -> Void) ($s) { }
sub check :sig((Outer) -> Void) ($o) {
    if (defined($o->inner->value)) {
        takes_str($o->inner->value);
    }
    takes_str($o->inner->value);
}
PERL

    # Currently: 2 errors (both inside and outside branch, multi-level not narrowed)
    # After implementation: should be exactly 1 error (only outside the branch)
    ok scalar @$errs >= 1,
        'narrowing does not leak past if-block for multi-level chain';
};

# ════════════════════════════════════════════════════════════
# Section 11: Single-level baseline (should always pass)
#   Verify single-level accessor narrowing still works
# ════════════════════════════════════════════════════════════

subtest 'baseline: single-level if (defined($o->field))' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Widget => (optional(tip => 'Str'));
sub get_tip :sig((Widget) -> Str) ($w) {
    if (defined($w->tip)) {
        return $w->tip;
    }
    return "none";
}
PERL

    is scalar @$errs, 0,
        'single-level defined accessor narrowing works (baseline)';
};

subtest 'baseline: single-level early return' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Widget => (optional(tip => 'Str'));
sub get_tip :sig((Widget) -> Str) ($w) {
    return "none" unless defined($w->tip);
    return $w->tip;
}
PERL

    is scalar @$errs, 0,
        'single-level early return accessor narrowing works (baseline)';
};

subtest 'baseline: single-level ternary' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Widget => (optional(tip => 'Str'));
sub get_tip :sig((Widget) -> Str) ($w) {
    return defined($w->tip) ? $w->tip : "none";
}
PERL

    is scalar @$errs, 0,
        'single-level ternary accessor narrowing works (baseline)';
};

# ════════════════════════════════════════════════════════════
# Section 12: Combined multi-level and variable narrowing
# ════════════════════════════════════════════════════════════

subtest 'multilevel: && combined variable and accessor narrowing' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Inner => (optional(value => 'Str'));
struct Outer => (inner => 'Inner');
sub check :sig((Maybe[Outer]) -> Str) ($o) {
    if (defined($o) && defined($o->inner->value)) {
        return $o->inner->value;
    }
    return "default";
}
PERL

    # DESIGN_GAP: compound && with mixed variable + accessor narrowing.
    # The variable gets narrowed but accessor narrowing is not accumulated
    # across && segments (same limitation exists for single-level).
    ok scalar @$errs >= 1,
        'compound && variable + accessor narrowing not yet combined (design gap)';
};

done_testing;
