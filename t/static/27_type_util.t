use v5.40;
use Test::More;

use Typist::Static::TypeUtil qw(widen_literal contains_any contains_placeholder);
use Typist::Type::Atom;
use Typist::Type::Literal;
use Typist::Type::Param;
use Typist::Type::Func;
use Typist::Type::Union;
use Typist::Type::Var;

my $Int  = Typist::Type::Atom->new('Int');
my $Str  = Typist::Type::Atom->new('Str');
my $Any  = Typist::Type::Atom->new('Any');
my $Hole = Typist::Type::Atom->new('_');

# ── widen_literal ────────────────────────────────

subtest 'widen_literal — base cases' => sub {
    my $lit_int = Typist::Type::Literal->new(42, 'Int');
    my $widened = widen_literal($lit_int);
    ok $widened->is_atom, 'literal widened to atom';
    is $widened->name, 'Int', 'Int literal → Int atom';

    my $lit_str = Typist::Type::Literal->new("hello", 'Str');
    $widened = widen_literal($lit_str);
    is $widened->name, 'Str', 'Str literal → Str atom';

    my $lit_bool = Typist::Type::Literal->new(1, 'Bool');
    $widened = widen_literal($lit_bool);
    is $widened->name, 'Int', 'Bool literal → Int atom (widened)';
};

subtest 'widen_literal — non-literal passthrough' => sub {
    my $widened = widen_literal($Int);
    ok $widened->equals($Int), 'atom passes through';

    my $var = Typist::Type::Var->new('T');
    $widened = widen_literal($var);
    ok $widened->is_var, 'var passes through';
};

subtest 'widen_literal — Param recursion' => sub {
    my $lit = Typist::Type::Literal->new(42, 'Int');
    my $param = Typist::Type::Param->new('ArrayRef', $lit);
    my $widened = widen_literal($param);
    ok $widened->is_param, 'param structure preserved';
    my ($inner) = $widened->params;
    ok $inner->is_atom, 'inner literal widened';
    is $inner->name, 'Int', 'inner widened to Int';

    # No change → same object returned
    my $param2 = Typist::Type::Param->new('ArrayRef', $Int);
    my $widened2 = widen_literal($param2);
    ok $widened2->equals($param2), 'no-change Param passes through';
};

# ── contains_any ─────────────────────────────────

subtest 'contains_any — direct Any' => sub {
    ok contains_any($Any), 'Any detected';
    ok !contains_any($Int), 'Int is not Any';
};

subtest 'contains_any — nested in Func' => sub {
    my $f = Typist::Type::Func->new([$Any], $Int);
    ok contains_any($f), 'Any in func params';

    my $f2 = Typist::Type::Func->new([$Int], $Any);
    ok contains_any($f2), 'Any in func return';

    my $f3 = Typist::Type::Func->new([$Int], $Str);
    ok !contains_any($f3), 'no Any in clean func';
};

subtest 'contains_any — nested in Union' => sub {
    my $u = Typist::Type::Union->new($Int, $Any);
    ok contains_any($u), 'Any in union';

    my $u2 = Typist::Type::Union->new($Int, $Str);
    ok !contains_any($u2), 'no Any in clean union';
};

subtest 'contains_any — placeholder detected' => sub {
    ok contains_any($Hole), '_ placeholder detected as Any-like';
};

# ── contains_placeholder ─────────────────────────

subtest 'contains_placeholder — direct' => sub {
    ok contains_placeholder($Hole), '_ detected';
    ok !contains_placeholder($Int), 'Int is not _';
};

subtest 'contains_placeholder — nested in Param' => sub {
    my $p = Typist::Type::Param->new('ArrayRef', $Hole);
    ok contains_placeholder($p), '_ in Param detected';
};

subtest 'contains_placeholder — nested in Func' => sub {
    my $f = Typist::Type::Func->new([$Hole], $Int);
    ok contains_placeholder($f), '_ in func params detected';

    my $f2 = Typist::Type::Func->new([$Int], $Hole);
    ok contains_placeholder($f2), '_ in func return detected';
};

subtest 'contains_placeholder — nested in Union' => sub {
    my $u = Typist::Type::Union->new($Int, $Hole);
    ok contains_placeholder($u), '_ in union detected';
};

done_testing;
