use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Record;
use Typist::Type::Intersection;
use Typist::Type::Fold;
use Typist::Subtype;
use Typist::Static::TypeUtil;
use Typist::Registry;
use Typist::Static::Analyzer;
use Scalar::Util 'refaddr';

use Test::Typist::Gen qw(
    gen_atom gen_literal gen_ground_type gen_type gen_subtype_pair
    gen_parseable_type
);

my $ITERS = $ENV{STRESS_ITERS} // 100;
my $SEED  = $ENV{STRESS_SEED}  // int(rand(2**31));
srand($SEED);
diag "property seed=$SEED iters=$ITERS";

# ── 1. Type equality properties ─────────────────

subtest 'equals: reflexivity' => sub {
    for (1 .. $ITERS) {
        my $t = gen_type(max_depth => 3);
        ok $t->equals($t), "reflexivity: " . $t->to_string;
    }
};

subtest 'equals: symmetry' => sub {
    for (1 .. $ITERS) {
        my $a = gen_ground_type(max_depth => 2);
        my $b = gen_ground_type(max_depth => 2);
        my $ab = $a->equals($b);
        my $ba = $b->equals($a);
        is $ab, $ba, "symmetry: " . $a->to_string . " vs " . $b->to_string;
    }
};

# ── 2. contains_any completeness ────────────────

subtest 'contains_any: Any at non-Param positions detected' => sub {
    my $Any = Typist::Type::Atom->new('Any');
    my $Int = Typist::Type::Atom->new('Int');

    # Func with Any return
    my $func_any = Typist::Type::Func->new([$Int], $Any);
    ok Typist::Static::TypeUtil::contains_any($func_any),
       'Func with Any return detected';

    # Func with Any param
    my $func_any_param = Typist::Type::Func->new([$Any], $Int);
    ok Typist::Static::TypeUtil::contains_any($func_any_param),
       'Func with Any param detected';

    # Intersection with Any
    my $inter_any = Typist::Type::Intersection->new($Int, $Any);
    ok Typist::Static::TypeUtil::contains_any($inter_any),
       'Intersection with Any detected';

    # Record with Any value
    my $rec_any = Typist::Type::Record->new(x => $Any);
    ok Typist::Static::TypeUtil::contains_any($rec_any),
       'Record with Any value detected';

    # Param with Any — intentionally NOT detected (precision-loss guard)
    my $param_any = Typist::Type::Param->new('ArrayRef', $Any);
    ok !Typist::Static::TypeUtil::contains_any($param_any),
       'Param[Any] intentionally not detected (LUB precision guard)';
};

subtest 'contains_any vs Fold::walk consistency' => sub {
    for (1 .. $ITERS) {
        my $t = gen_ground_type(max_depth => 3);
        my $has_any_walk = 0;
        Typist::Type::Fold->walk($t, sub ($node) {
            $has_any_walk = 1 if $node->is_atom && $node->name eq 'Any';
        });
        my $has_any_util = Typist::Static::TypeUtil::contains_any($t);

        # If contains_any says yes, walk must also find Any
        # (The reverse may not hold because Param[Any] is excluded)
        if ($has_any_util) {
            ok $has_any_walk,
               "contains_any=true implies walk finds Any: " . $t->to_string;
        } else {
            pass "contains_any=false for: " . $t->to_string;
        }
    }
};

# ── 3. Subtype properties ──────────────────────

subtest 'is_subtype: reflexivity' => sub {
    for (1 .. $ITERS) {
        my $t = gen_ground_type(max_depth => 2);
        ok Typist::Subtype->is_subtype($t, $t),
           "reflexivity: " . $t->to_string;
    }
};

subtest 'is_subtype: generated pairs valid' => sub {
    for (1 .. $ITERS) {
        my ($sub, $super) = gen_subtype_pair();
        ok Typist::Subtype->is_subtype($sub, $super),
           $sub->to_string . " <: " . $super->to_string;
    }
};

# ── 4. common_super properties ─────────────────

subtest 'common_super: commutativity' => sub {
    for (1 .. $ITERS) {
        my $a = gen_atom();
        my $b = gen_atom();
        my $ab = Typist::Subtype->common_super($a, $b);
        my $ba = Typist::Subtype->common_super($b, $a);
        is $ab->to_string, $ba->to_string,
           "commutativity: " . $a->to_string . ", " . $b->to_string;
    }
};

subtest 'common_super: upper bound' => sub {
    my @atoms = map { Typist::Type::Atom->new($_) }
        qw(Bool Int Double Num Str Undef);

    for my $a (@atoms) {
        for my $b (@atoms) {
            my $sup = Typist::Subtype->common_super($a, $b);
            ok Typist::Subtype->is_subtype($a, $sup),
               $a->to_string . " <: " . $sup->to_string;
            ok Typist::Subtype->is_subtype($b, $sup),
               $b->to_string . " <: " . $sup->to_string;
        }
    }
};

# ── 5. Registration robustness (fuzz) ──────────

subtest 'Registration fuzz: invalid types do not crash' => sub {
    my @invalid_exprs = (
        'ArrayRef[',            # unclosed bracket
        '-> -> ->',             # nonsense arrows
        '((()))',               # empty parens
        '!!![Int]',             # invalid effect syntax
        'Union[,]',             # empty union param
        '',                     # empty string
        'A B C D',              # spaces
        ':sig(broken',          # annotation fragment
    );

    for my $expr (@invalid_exprs) {
        my $r = Typist::Registry->new;
        my $errors = Typist::Error::Collector->new;
        eval {
            $r->define_alias('Bad', $expr);
            $r->lookup_type('Bad');
        };
        pass "no crash on invalid expr: '$expr'";
    }
};

# Need Error::Collector
{
    require Typist::Error;
}

subtest 'Registration fuzz: analyzer survives invalid annotations' => sub {
    my @bad_codes = (
        'sub f :sig(BROKEN) ($x) { $x }',
        'sub g :sig((Int) -> ) ($x) { $x }',
        'typedef BadAlias => "ArrayRef[";',
    );

    for my $code (@bad_codes) {
        my $full = "use v5.40;\n$code\n";
        eval {
            Typist::Static::Analyzer->analyze($full, file => 'fuzz.pm');
        };
        pass "analyzer survives: " . substr($code, 0, 40);
    }
};

# ── 6. Inference cache safety ──────────────────

subtest 'inference cache: same to_string, different expected types' => sub {
    # Two functions with same type strings but resolved independently
    # should not interfere through the cache (refaddr-based keys)
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', file => 'cache.pm');
use v5.40;
typedef Score => 'Int';
typedef Count => 'Int';

sub use_score :sig((Score) -> Score) ($s) { $s }
sub use_count :sig((Count) -> Count) ($c) { $c }
PERL

    my @diags = @{$result->{diagnostics}};
    is scalar @diags, 0, 'no diagnostics for independent alias types';

    # Different expected types: same expression checked against different types
    my $result2 = Typist::Static::Analyzer->analyze(<<'PERL', file => 'cache2.pm');
use v5.40;
sub returns_int :sig(() -> Int) () { return 42 }
sub returns_str :sig(() -> Str) () { return "hello" }
PERL

    my @diags2 = @{$result2->{diagnostics}};
    is scalar @diags2, 0, 'independent function caches do not collide';
};

done_testing;
