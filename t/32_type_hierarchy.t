use v5.40;
use Test::More;
use lib 'lib';

use Typist::Type::Atom;
use Typist::Type::Var;
use Typist::Type::Literal;
use Typist::Type::Alias;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Record;
use Typist::Type::Struct;
use Typist::Type::Data;
use Typist::Type::Newtype;
use Typist::Type::Quantified;
use Typist::Type::Row;
use Typist::Type::Eff;
use Typist::Type::Param;
use Typist::Type::Fold;
use Typist::Type;

# ── Helpers ──────────────────────────────────────

my $Int  = Typist::Type::Atom->new('Int');
my $Str  = Typist::Type::Atom->new('Str');
my $Bool = Typist::Type::Atom->new('Bool');
my $Num  = Typist::Type::Atom->new('Num');
my $Any  = Typist::Type::Atom->new('Any');

# ── _normalize_members (Union/Intersection共通化) ──

subtest '_normalize_members — flatten and dedup' => sub {
    # Flatten nested unions
    my $inner = Typist::Type::Union->new($Int, $Str);
    my @norm  = Typist::Type->_normalize_members('is_union', $inner, $Bool);
    is scalar @norm, 3, 'flattened nested union yields 3 members';

    # Dedup
    my @dedup = Typist::Type->_normalize_members('is_union', $Int, $Int, $Str);
    is scalar @dedup, 2, 'duplicate removed';

    # Flatten nested intersections
    my $inner_i = Typist::Type::Intersection->new($Int, $Str);
    my @norm_i  = Typist::Type->_normalize_members('is_intersection', $inner_i, $Bool);
    is scalar @norm_i, 3, 'flattened nested intersection yields 3 members';

    # Single member
    my @single = Typist::Type->_normalize_members('is_union', $Int);
    is scalar @single, 1, 'single member preserved';

    # Empty
    my @empty = Typist::Type->_normalize_members('is_union');
    is scalar @empty, 0, 'empty input yields empty output';
};

subtest 'Union constructor uses _normalize_members' => sub {
    # Nested flattening
    my $u1 = Typist::Type::Union->new($Int, $Str);
    my $u2 = Typist::Type::Union->new($u1, $Bool);
    is scalar(scalar [$u2->members]->@*), 3, 'nested union flattened';

    # Dedup collapses to single
    my $u3 = Typist::Type::Union->new($Int, $Int);
    ok $u3->is_atom, 'single-member union collapsed to atom';
    is $u3->name, 'Int', 'collapsed union is Int';

    # Three-way dedup
    my $u4 = Typist::Type::Union->new($Int, $Str, $Int);
    is scalar(scalar [$u4->members]->@*), 2, 'three-way dedup';
};

subtest 'Intersection constructor uses _normalize_members' => sub {
    my $i1 = Typist::Type::Intersection->new($Int, $Str);
    my $i2 = Typist::Type::Intersection->new($i1, $Bool);
    is scalar(scalar [$i2->members]->@*), 3, 'nested intersection flattened';

    my $i3 = Typist::Type::Intersection->new($Int, $Int);
    ok $i3->is_atom, 'single-member intersection collapsed';
};

# ── _zip_type_bindings ───────────────────────────

subtest '_zip_type_bindings' => sub {
    my %b = Typist::Type->_zip_type_bindings(['T', 'U'], [$Int, $Str]);
    ok $b{T}->equals($Int), 'T bound to Int';
    ok $b{U}->equals($Str), 'U bound to Str';

    # Mismatched lengths: shorter wins
    my %b2 = Typist::Type->_zip_type_bindings(['T', 'U', 'V'], [$Int]);
    is scalar keys %b2, 1, 'only 1 binding when args shorter';
    ok $b2{T}->equals($Int), 'T bound correctly';

    # Empty
    my %b3 = Typist::Type->_zip_type_bindings([], []);
    is scalar keys %b3, 0, 'empty zip';
};

# ── Quantified.equals uses is_quantified ─────────

subtest 'Quantified.equals uses is_quantified predicate' => sub {
    my $q1 = Typist::Type::Quantified->new(
        vars => [{ name => 'T' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('T')],
            Typist::Type::Var->new('T'),
        ),
    );
    my $q2 = Typist::Type::Quantified->new(
        vars => [{ name => 'T' }],
        body => Typist::Type::Func->new(
            [Typist::Type::Var->new('T')],
            Typist::Type::Var->new('T'),
        ),
    );
    ok $q1->equals($q2), 'equal quantified types';
    ok !$q1->equals($Int), 'quantified != atom';

    # With bounds
    my $q3 = Typist::Type::Quantified->new(
        vars => [{ name => 'T', bound => $Num }],
        body => Typist::Type::Var->new('T'),
    );
    my $q4 = Typist::Type::Quantified->new(
        vars => [{ name => 'T', bound => $Num }],
        body => Typist::Type::Var->new('T'),
    );
    ok $q3->equals($q4), 'equal bounded quantified types';

    # Different bounds
    my $q5 = Typist::Type::Quantified->new(
        vars => [{ name => 'T', bound => $Str }],
        body => Typist::Type::Var->new('T'),
    );
    ok !$q3->equals($q5), 'different bounds are not equal';
};

# ── Newtype.to_string consistency ─────────────────

subtest 'Newtype.to_string — no interpolation wrapper' => sub {
    my $nt = Typist::Type::Newtype->new('UserId', $Int);
    is $nt->to_string, 'UserId', 'to_string returns bare name';
    is "$nt", 'UserId', 'stringify overload works';
};

# ── Func.to_string — variadic ────────────────────

subtest 'Func.to_string — variadic formatting' => sub {
    my $f = Typist::Type::Func->new([$Int, $Str], $Bool, undef, variadic => 1);
    is $f->to_string, '(Int, ...Str) -> Bool', 'variadic prefix on last param';

    # Non-variadic
    my $f2 = Typist::Type::Func->new([$Int, $Str], $Bool);
    is $f2->to_string, '(Int, Str) -> Bool', 'no variadic prefix';

    # Single variadic param
    my $f3 = Typist::Type::Func->new([$Str], $Bool, undef, variadic => 1);
    is $f3->to_string, '(...Str) -> Bool', 'single variadic param';

    # Empty params
    my $f4 = Typist::Type::Func->new([], $Bool);
    is $f4->to_string, '() -> Bool', 'empty params';
};

# ── Alias.equals simplification ───────────────────

subtest 'Alias.equals — simplified guard' => sub {
    my $a1 = Typist::Type::Alias->new('Foo');
    my $a2 = Typist::Type::Alias->new('Foo');
    my $a3 = Typist::Type::Alias->new('Bar');

    ok $a1->equals($a2),  'same alias name → equal';
    ok !$a1->equals($a3), 'different alias name → not equal';
    ok !$a1->equals($Int), 'alias vs atom → not equal (unless resolved)';
};

# ── Record.fields — merged declaration ────────────

subtest 'Record.fields — clean declaration' => sub {
    my $rec = Typist::Type::Record->new(name => $Str, 'age?' => $Int);
    my %f = $rec->fields;
    is scalar keys %f, 2, 'two fields';
    ok exists $f{name},  'required field present';
    ok exists $f{'age?'}, 'optional field with ? suffix';
};

# ── Row.equals — element-wise comparison ──────────

subtest 'Row.equals — element-wise state comparison' => sub {
    my $r1 = Typist::Type::Row->new(
        labels       => ['DB'],
        label_states => +{ DB => +{ from => ['Open'], to => ['Closed'] } },
    );
    my $r2 = Typist::Type::Row->new(
        labels       => ['DB'],
        label_states => +{ DB => +{ from => ['Open'], to => ['Closed'] } },
    );
    ok $r1->equals($r2), 'identical label states';

    my $r3 = Typist::Type::Row->new(
        labels       => ['DB'],
        label_states => +{ DB => +{ from => ['Open'], to => ['Open'] } },
    );
    ok !$r1->equals($r3), 'different to-state';

    # Multi-state (order independent)
    my $r4 = Typist::Type::Row->new(
        labels       => ['DB'],
        label_states => +{ DB => +{ from => ['A', 'B'], to => ['C'] } },
    );
    my $r5 = Typist::Type::Row->new(
        labels       => ['DB'],
        label_states => +{ DB => +{ from => ['B', 'A'], to => ['C'] } },
    );
    ok $r4->equals($r5), 'state order independent in comparison';
};

# ── Fold.map_type — elsif chain consistency ───────

subtest 'Fold.map_type — identity transform' => sub {
    my $identity = sub ($t) { $t };

    # Test each type constructor through the fold
    my $union  = Typist::Type::Union->new($Int, $Str);
    my $mapped = Typist::Type::Fold->map_type($union, $identity);
    ok $mapped->equals($union), 'identity fold on Union';

    my $inter = Typist::Type::Intersection->new($Int, $Str);
    $mapped = Typist::Type::Fold->map_type($inter, $identity);
    ok $mapped->equals($inter), 'identity fold on Intersection';

    my $func = Typist::Type::Func->new([$Int], $Str);
    $mapped = Typist::Type::Fold->map_type($func, $identity);
    ok $mapped->equals($func), 'identity fold on Func';

    my $rec = Typist::Type::Record->new(x => $Int);
    $mapped = Typist::Type::Fold->map_type($rec, $identity);
    ok $mapped->equals($rec), 'identity fold on Record';

    my $param = Typist::Type::Param->new('ArrayRef', $Int);
    $mapped = Typist::Type::Fold->map_type($param, $identity);
    ok $mapped->equals($param), 'identity fold on Param';

    my $quant = Typist::Type::Quantified->new(
        vars => [{ name => 'T' }],
        body => Typist::Type::Var->new('T'),
    );
    $mapped = Typist::Type::Fold->map_type($quant, $identity);
    ok $mapped->equals($quant), 'identity fold on Quantified';
};

subtest 'Fold.map_type — rewrite transform' => sub {
    my $int_to_str = sub ($t) {
        $t->is_atom && $t->name eq 'Int' ? $Str : $t;
    };

    my $union = Typist::Type::Union->new($Int, $Bool);
    my $mapped = Typist::Type::Fold->map_type($union, $int_to_str);
    ok $mapped->is_union, 'result is still a union';
    my @m = $mapped->members;
    ok $m[0]->equals($Str), 'Int rewritten to Str';
    ok $m[1]->equals($Bool), 'Bool preserved';

    my $func = Typist::Type::Func->new([$Int], $Int);
    $mapped = Typist::Type::Fold->map_type($func, $int_to_str);
    ok $mapped->is_func, 'result is func';
    is $mapped->to_string, '(Str) -> Str', 'Int→Str in func params and return';
};

# ── Data/Struct contains with _zip_type_bindings ──

subtest 'Data.contains with zip bindings' => sub {
    my $T = Typist::Type::Var->new('T');
    my $data = Typist::Type::Data->new('Box', +{
        Wrap => [$T],
    }, type_params => ['T']);

    # Instantiate with Int
    my $box_int = $data->instantiate($Int);
    # Create a mock value
    my $val = bless +{
        _tag    => 'Wrap',
        _values => [42],
    }, 'Typist::Data::Box';
    ok $box_int->contains($val), 'Box[Int] contains Wrap(42)';

    my $bad_val = bless +{
        _tag    => 'Wrap',
        _values => ["hello"],
    }, 'Typist::Data::Box';
    ok !$box_int->contains($bad_val), 'Box[Int] rejects Wrap("hello")';
};

subtest 'Struct.contains with zip bindings' => sub {
    my $T = Typist::Type::Var->new('T');
    my $rec = Typist::Type::Record->new(val => $T);
    my $st = Typist::Type::Struct->new(
        name        => 'Container',
        record      => $rec,
        package     => 'Typist::Struct::Container',
        type_params => ['T'],
    );
    my $st_int = $st->instantiate($Int);

    my $val = bless +{ val => 42 }, 'Typist::Struct::Container';
    ok $st_int->contains($val), 'Container[Int] contains {val => 42}';

    my $bad = bless +{ val => "hello" }, 'Typist::Struct::Container';
    ok !$st_int->contains($bad), 'Container[Int] rejects {val => "hello"}';
};

# ── Edge cases ───────────────────────────────────

subtest 'Union — deeply nested flattening' => sub {
    my $u1 = Typist::Type::Union->new($Int, $Str);
    my $u2 = Typist::Type::Union->new($u1, $Bool);
    my $u3 = Typist::Type::Union->new($u2, $Num);
    is scalar(scalar [$u3->members]->@*), 4, 'three-level nesting flattened';
};

subtest 'Intersection — deeply nested flattening' => sub {
    my $i1 = Typist::Type::Intersection->new($Int, $Str);
    my $i2 = Typist::Type::Intersection->new($i1, $Bool);
    my $i3 = Typist::Type::Intersection->new($i2, $Num);
    is scalar(scalar [$i3->members]->@*), 4, 'three-level nesting flattened';
};

subtest 'Param.substitute — alias base normalization' => sub {
    my $alias_base = Typist::Type::Alias->new('ArrayRef');
    my $p = Typist::Type::Param->new($alias_base, $Int);
    my $subst = $p->substitute(+{});
    is $subst->to_string, 'ArrayRef[Int]', 'alias base normalized to string';
};

subtest 'Row.equals — empty label_states' => sub {
    my $r1 = Typist::Type::Row->new(labels => ['IO']);
    my $r2 = Typist::Type::Row->new(labels => ['IO']);
    ok $r1->equals($r2), 'rows without label_states are equal';
};

subtest 'Data.equals — GADT return type comparison' => sub {
    my $data1 = Typist::Type::Data->new('Expr', +{
        LitI => [$Int],
    }, return_types => +{ LitI => Typist::Type::Param->new('Expr', $Int) });
    my $data2 = Typist::Type::Data->new('Expr', +{
        LitI => [$Int],
    }, return_types => +{ LitI => Typist::Type::Param->new('Expr', $Int) });
    ok $data1->equals($data2), 'GADT return types compared correctly';

    my $data3 = Typist::Type::Data->new('Expr', +{
        LitI => [$Int],
    }, return_types => +{ LitI => Typist::Type::Param->new('Expr', $Str) });
    ok !$data1->equals($data3), 'different GADT return types are not equal';
};

subtest 'Quantified.contains — delegation' => sub {
    my $q = Typist::Type::Quantified->new(
        vars => [{ name => 'T' }],
        body => $Int,
    );
    ok $q->contains(42), 'quantified delegates to body';
    ok !$q->contains("hello"), 'quantified rejects via body';
};

done_testing;
