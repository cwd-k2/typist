#!/usr/bin/env perl
# Property-based tests for subtype, LUB, and unification metatheoretic properties.
# Seed control: TYPIST_PROP_SEED   (default: random)
# Iterations:   TYPIST_PROP_ITERS  (default: 200)

use v5.40;
use Test::More;
use lib 't/lib';

use Typist::Type::Atom;
use Typist::Type::Literal;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Param;
use Typist::Type::Var;
use Typist::Subtype;
use Typist::Static::Unify;
use Test::Typist::Gen qw(gen_atom gen_literal gen_ground_type gen_subtype_pair);

my $seed  = $ENV{TYPIST_PROP_SEED}  // int(rand(2**31));
my $iters = $ENV{TYPIST_PROP_ITERS} // 200;
srand($seed);
diag "property seed=$seed iters=$iters";

# ── Helpers ──────────────────────────────────────

sub is_sub ($sub, $super) {
    Typist::Subtype->is_subtype($sub, $super);
}

sub lub ($a, $b) {
    Typist::Subtype->common_super($a, $b);
}

sub type_eq ($a, $b) {
    $a->equals($b);
}

sub unify ($formal, $actual, $bindings = +{}) {
    Typist::Static::Unify->unify($formal, $actual, $bindings);
}

my $Any   = Typist::Type::Atom->new('Any');
my $Never = Typist::Type::Atom->new('Never');

# ── Subtype Properties ──────────────────────────

subtest 'subtype: reflexivity (T <: T)' => sub {
    for (1 .. $iters) {
        my $t = gen_ground_type(max_depth => 2);
        ok is_sub($t, $t), "reflexivity: $t <: $t"
            or last;
    }
};

subtest 'subtype: Never is bottom (Never <: T)' => sub {
    for (1 .. $iters) {
        my $t = gen_ground_type(max_depth => 2);
        ok is_sub($Never, $t), "bottom: Never <: $t"
            or last;
    }
};

subtest 'subtype: Any is top (T <: Any)' => sub {
    for (1 .. $iters) {
        my $t = gen_ground_type(max_depth => 2);
        ok is_sub($t, $Any), "top: $t <: Any"
            or last;
    }
};

subtest 'subtype: transitivity (atom chain)' => sub {
    # Use the atom hierarchy: Bool <: Int <: Double <: Num <: Any
    my @chain = map { Typist::Type::Atom->new($_) } qw(Bool Int Double Num Any);
    for my $i (0 .. $#chain) {
        for my $j ($i .. $#chain) {
            for my $k ($j .. $#chain) {
                my ($a, $b, $c) = @chain[$i, $j, $k];
                ok is_sub($a, $c),
                    "transitivity: $a <: $b <: $c => $a <: $c"
                    or last;
            }
        }
    }
};

subtest 'subtype: union introduction (T <: T|U)' => sub {
    for (1 .. $iters) {
        my $t = gen_atom();
        my $u = gen_atom();
        my $union = Typist::Type::Union->new($t, $u);
        ok is_sub($t, $union), "union intro: $t <: $t | $u"
            or last;
    }
};

subtest 'subtype: intersection elimination (T&U <: T)' => sub {
    for (1 .. $iters) {
        my $t = gen_atom();
        my $u = gen_atom();
        my $inter = Typist::Type::Intersection->new($t, $u);
        # Intersection may collapse to a single type if t equals u
        ok is_sub($inter, $t), "inter elim: $t & $u <: $t"
            or last;
    }
};

subtest 'subtype: function contravariance' => sub {
    for (1 .. $iters) {
        my ($sub_param, $super_param) = gen_subtype_pair();
        my ($sub_ret, $super_ret) = gen_subtype_pair();
        # Func(super_param) -> sub_ret  <:  Func(sub_param) -> super_ret
        my $f1 = Typist::Type::Func->new([$super_param], $sub_ret);
        my $f2 = Typist::Type::Func->new([$sub_param], $super_ret);
        ok is_sub($f1, $f2),
            "contravariance: ($super_param)->$sub_ret <: ($sub_param)->$super_ret"
            or last;
    }
};

subtest 'subtype: generated pairs (sub <: super)' => sub {
    for (1 .. $iters) {
        my ($sub, $super) = gen_subtype_pair();
        ok is_sub($sub, $super), "gen pair: $sub <: $super"
            or last;
    }
};

# ── LUB Properties ──────────────────────────────

subtest 'LUB: upper bound (T <: lub(T,U) and U <: lub(T,U))' => sub {
    for (1 .. $iters) {
        my $t = gen_atom();
        my $u = gen_atom();
        my $l = lub($t, $u);
        ok is_sub($t, $l), "upper bound left: $t <: lub($t,$u) = $l"
            or last;
        ok is_sub($u, $l), "upper bound right: $u <: lub($t,$u) = $l"
            or last;
    }
};

subtest 'LUB: commutativity (lub(T,U) = lub(U,T))' => sub {
    for (1 .. $iters) {
        my $t = gen_atom();
        my $u = gen_atom();
        my $l1 = lub($t, $u);
        my $l2 = lub($u, $t);
        ok type_eq($l1, $l2),
            "commutativity: lub($t,$u) = $l1, lub($u,$t) = $l2"
            or last;
    }
};

subtest 'LUB: idempotence (lub(T,T) = T)' => sub {
    for (1 .. $iters) {
        my $t = gen_atom();
        my $l = lub($t, $t);
        ok type_eq($l, $t), "idempotence: lub($t,$t) = $l"
            or last;
    }
};

# ── Unification Properties ──────────────────────

subtest 'unify: self-unification (ground type)' => sub {
    for (1 .. $iters) {
        my $t = gen_ground_type(max_depth => 2);
        my $result = unify($t, $t);
        ok defined $result, "self-unify succeeds: $t"
            or last;
        is_deeply $result, +{}, "self-unify has empty bindings: $t"
            or last;
    }
};

subtest 'unify: variable binding' => sub {
    for (1 .. $iters) {
        my $t = gen_ground_type(max_depth => 1);
        # Skip Any — unify skips binding Var to Any (gradual typing)
        next if $t->is_atom && $t->name eq 'Any';
        my $var = Typist::Type::Var->new('X');
        my $result = unify($var, $t);
        ok defined $result, "var binding succeeds: X ~ $t"
            or last;
        ok type_eq($result->{X}, $t), "binding: X => $t (got $result->{X})"
            or last;
    }
};

subtest 'unify: Var to Any skips binding' => sub {
    my $var = Typist::Type::Var->new('X');
    my $result = unify($var, $Any);
    ok defined $result, 'unify(X, Any) succeeds';
    ok !exists $result->{X}, 'X not bound (Any carries no information)';
};

done_testing;
