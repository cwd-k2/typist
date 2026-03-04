use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Unify;
use Typist::Type::Atom;
use Typist::Type::Var;
use Typist::Type::Param;
use Typist::Type::Func;
use Typist::Type::Record;
use Typist::Type::Literal;
use Typist::Type::Quantified;

sub atom ($n) { Typist::Type::Atom->new($n) }
sub var  ($n) { Typist::Type::Var->new($n) }

# ── Basic variable binding ─────────────────────

subtest 'basic variable binding' => sub {
    my $result = Typist::Static::Unify->unify(var('T'), atom('Int'));
    ok $result, 'unification succeeds';
    is $result->{T}->to_string, 'Int', 'T bound to Int';
};

subtest 'atom-atom match' => sub {
    my $result = Typist::Static::Unify->unify(atom('Int'), atom('Int'));
    ok $result, 'same atoms unify';
    is scalar(keys %$result), 0, 'no bindings needed';
};

subtest 'atom-atom mismatch' => sub {
    my $result = Typist::Static::Unify->unify(atom('Int'), atom('Str'));
    ok !defined $result, 'different atoms fail';
};

# ── Widening via common_super ──────────────────

subtest 'partial binding widening' => sub {
    # First bind T → Int, then unify T with Bool → widened to Int (LUB)
    my $bindings = Typist::Static::Unify->unify(var('T'), atom('Int'));
    ok $bindings, 'first binding succeeds';
    $bindings = Typist::Static::Unify->unify(var('T'), atom('Bool'), $bindings);
    ok $bindings, 'second binding succeeds with widening';
    is $bindings->{T}->to_string, 'Int', 'T widened to Int (LUB of Int, Bool)';
};

subtest 'widening with Str and Int' => sub {
    my $bindings = Typist::Static::Unify->unify(var('T'), atom('Int'));
    $bindings = Typist::Static::Unify->unify(var('T'), atom('Str'), $bindings);
    ok $bindings, 'widening succeeds';
    is $bindings->{T}->to_string, 'Any', 'T widened to Any (LUB of Int, Str)';
};

# ── Literal unification ────────────────────────

subtest 'atom formal vs literal actual' => sub {
    my $lit = Typist::Type::Literal->new(42, 'Int');
    my $result = Typist::Static::Unify->unify(atom('Int'), $lit);
    ok $result, 'Int unifies with Literal(42, Int)';

    my $fail = Typist::Static::Unify->unify(atom('Str'), $lit);
    ok !defined $fail, 'Str does not unify with Literal(42, Int)';
};

subtest 'variable binding to literal' => sub {
    my $lit = Typist::Type::Literal->new("hello", 'Str');
    my $result = Typist::Static::Unify->unify(var('T'), $lit);
    ok $result, 'T binds to literal';
    ok $result->{T}->is_literal, 'bound type is literal';
};

# ── Param unification ──────────────────────────

subtest 'param base match + recursive' => sub {
    my $formal = Typist::Type::Param->new('ArrayRef', var('T'));
    my $actual = Typist::Type::Param->new('ArrayRef', atom('Int'));
    my $result = Typist::Static::Unify->unify($formal, $actual);
    ok $result, 'ArrayRef[T] unifies with ArrayRef[Int]';
    is $result->{T}->to_string, 'Int', 'T = Int';
};

subtest 'param base mismatch' => sub {
    my $formal = Typist::Type::Param->new('ArrayRef', var('T'));
    my $actual = Typist::Type::Param->new('HashRef', atom('Int'));
    my $result = Typist::Static::Unify->unify($formal, $actual);
    ok !defined $result, 'ArrayRef[T] does not unify with HashRef[Int]';
};

subtest 'nested param unification' => sub {
    my $formal = Typist::Type::Param->new('ArrayRef',
        Typist::Type::Param->new('ArrayRef', var('T')));
    my $actual = Typist::Type::Param->new('ArrayRef',
        Typist::Type::Param->new('ArrayRef', atom('Str')));
    my $result = Typist::Static::Unify->unify($formal, $actual);
    ok $result, 'nested param unifies';
    is $result->{T}->to_string, 'Str', 'T = Str';
};

# ── HKT unification ───────────────────────────

subtest 'HKT: F[A] vs ArrayRef[Int]' => sub {
    my $f_var = Typist::Type::Var->new('F');
    my $a_var = Typist::Type::Var->new('A');
    my $formal = Typist::Type::Param->new($f_var, $a_var);
    my $actual = Typist::Type::Param->new('ArrayRef', atom('Int'));
    my $result = Typist::Static::Unify->unify($formal, $actual);
    ok $result, 'F[A] unifies with ArrayRef[Int]';
    is $result->{F}->to_string, 'ArrayRef', 'F = ArrayRef';
    is $result->{A}->to_string, 'Int', 'A = Int';
};

# ── Func unification ──────────────────────────

subtest 'func params + return' => sub {
    my $formal = Typist::Type::Func->new([var('T')], var('U'));
    my $actual = Typist::Type::Func->new([atom('Int')], atom('Str'));
    my $result = Typist::Static::Unify->unify($formal, $actual);
    ok $result, 'func unifies';
    is $result->{T}->to_string, 'Int', 'T = Int';
    is $result->{U}->to_string, 'Str', 'U = Str';
};

subtest 'func arity mismatch' => sub {
    my $formal = Typist::Type::Func->new([var('T'), var('U')], atom('Int'));
    my $actual = Typist::Type::Func->new([atom('Int')], atom('Int'));
    my $result = Typist::Static::Unify->unify($formal, $actual);
    ok !defined $result, 'arity mismatch fails';
};

# ── Record field-wise unification ──────────────

subtest 'record field-wise' => sub {
    my $formal = Typist::Type::Record->new(x => var('T'), y => atom('Str'));
    my $actual = Typist::Type::Record->new(x => atom('Int'), y => atom('Str'));
    my $result = Typist::Static::Unify->unify($formal, $actual);
    ok $result, 'record unifies field-wise';
    is $result->{T}->to_string, 'Int', 'T = Int';
};

subtest 'record missing field skipped' => sub {
    my $formal = Typist::Type::Record->new(x => var('T'), z => atom('Bool'));
    my $actual = Typist::Type::Record->new(x => atom('Int'));
    my $result = Typist::Static::Unify->unify($formal, $actual);
    ok $result, 'missing field in actual is skipped';
    is $result->{T}->to_string, 'Int', 'T = Int';
};

# ── Quantified instantiation ──────────────────

subtest 'quantified body unification' => sub {
    my $quant = Typist::Type::Quantified->new(
        vars => [{ name => 'T' }],
        body => Typist::Type::Func->new([var('T')], var('T')),
    );
    my $actual = Typist::Type::Func->new([atom('Int')], atom('Int'));
    my $result = Typist::Static::Unify->unify($quant, $actual);
    ok $result, 'quantified body unifies with concrete';
    is $result->{T}->to_string, 'Int', 'T = Int';
};

# ── collect_bindings: conflict rejection ───────

subtest 'collect_bindings conflict rejection' => sub {
    my %bindings;
    my $ok1 = Typist::Static::Unify->collect_bindings(var('T'), atom('Int'), \%bindings);
    ok $ok1, 'first binding succeeds';
    is $bindings{T}->to_string, 'Int', 'T = Int';

    my $ok2 = Typist::Static::Unify->collect_bindings(var('T'), atom('Str'), \%bindings);
    ok !$ok2, 'conflicting binding rejected';
};

subtest 'collect_bindings skips Any' => sub {
    my %bindings;
    my $ok = Typist::Static::Unify->collect_bindings(var('T'), atom('Any'), \%bindings);
    ok $ok, 'binding to Any succeeds';
    ok !exists $bindings{T}, 'T not bound (Any skipped)';
};

subtest 'collect_bindings HKT' => sub {
    my $f_var = Typist::Type::Var->new('F');
    my $a_var = Typist::Type::Var->new('A');
    my $formal = Typist::Type::Param->new($f_var, $a_var);
    my $actual = Typist::Type::Param->new('ArrayRef', atom('Int'));
    my %bindings;
    my $ok = Typist::Static::Unify->collect_bindings($formal, $actual, \%bindings);
    ok $ok, 'HKT binding succeeds';
    is $bindings{F}->to_string, 'ArrayRef', 'F = ArrayRef';
    is $bindings{A}->to_string, 'Int', 'A = Int';
};

# ── Substitute ─────────────────────────────────

subtest 'substitute replaces vars' => sub {
    my $type = Typist::Type::Func->new([var('T')], var('U'));
    my $result = Typist::Static::Unify->substitute($type, {
        T => atom('Int'),
        U => atom('Str'),
    });
    is(($result->params)[0]->to_string, 'Int', 'T replaced');
    is $result->returns->to_string, 'Str', 'U replaced';
};

done_testing;
