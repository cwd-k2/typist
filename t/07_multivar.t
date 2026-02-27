use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;
use Typist::Transform;
use Typist::Type::Var;

# ── Transform: aliases_to_vars ─────────────────

subtest 'single multi-char var' => sub {
    my $type = Typist::Parser->parse('ArrayRef[Elem]');
    ok $type->is_param, 'parsed as param';
    my ($inner) = $type->params;
    ok $inner->is_alias, 'Elem parsed as alias initially';

    my $transformed = Typist::Transform->aliases_to_vars($type, +{ Elem => 1 });
    ok $transformed->is_param, 'still param after transform';
    my ($t_inner) = $transformed->params;
    ok $t_inner->is_var, 'Elem transformed to var';
    is $t_inner->name, 'Elem', 'var name is Elem';
};

subtest 'multiple vars in function type' => sub {
    my $type = Typist::Parser->parse('CodeRef[Key, Value -> Result]');
    my $transformed = Typist::Transform->aliases_to_vars(
        $type, +{ Key => 1, Value => 1, Result => 1 }
    );
    ok $transformed->is_func, 'func after transform';
    my @params = $transformed->params;
    ok $params[0]->is_var && $params[0]->name eq 'Key',   'Key is var';
    ok $params[1]->is_var && $params[1]->name eq 'Value', 'Value is var';
    ok $transformed->returns->is_var && $transformed->returns->name eq 'Result', 'Result is var';
};

subtest 'preserves non-variable aliases' => sub {
    my $type = Typist::Parser->parse('ArrayRef[UserId]');
    my $transformed = Typist::Transform->aliases_to_vars($type, +{ Elem => 1 });
    my ($inner) = $transformed->params;
    ok $inner->is_alias, 'UserId remains alias (not declared as var)';
    is $inner->alias_name, 'UserId', 'alias name preserved';
};

subtest 'preserves single-char vars' => sub {
    my $type = Typist::Parser->parse('ArrayRef[T]');
    my ($inner) = $type->params;
    ok $inner->is_var, 'T is already a var from parser';

    my $transformed = Typist::Transform->aliases_to_vars($type, +{ T => 1 });
    my ($t_inner) = $transformed->params;
    ok $t_inner->is_var, 'T remains var after transform';
    is $t_inner->name, 'T', 'name is T';
};

subtest 'transform in struct' => sub {
    my $type = Typist::Parser->parse('{ items => ArrayRef[Elem], count => Int }');
    my $transformed = Typist::Transform->aliases_to_vars($type, +{ Elem => 1 });
    my %req = $transformed->required_fields;
    my ($elem) = $req{items}->params;
    ok $elem->is_var, 'Elem in struct field transformed';
    ok $req{count}->is_atom, 'Int in struct preserved';
};

subtest 'transform in union and intersection' => sub {
    my $u = Typist::Parser->parse('Elem | Int');
    my $tu = Typist::Transform->aliases_to_vars($u, +{ Elem => 1 });
    ok $tu->is_union, 'still union';
    my @m = $tu->members;
    ok $m[0]->is_var && $m[0]->name eq 'Elem', 'Elem in union transformed';

    my $i = Typist::Parser->parse('Elem & Num');
    my $ti = Typist::Transform->aliases_to_vars($i, +{ Elem => 1 });
    ok $ti->is_intersection, 'still intersection';
    my @mi = $ti->members;
    ok $mi[0]->is_var && $mi[0]->name eq 'Elem', 'Elem in intersection transformed';
};

subtest 'free_vars reports multi-char names' => sub {
    my $type = Typist::Parser->parse('CodeRef[Elem -> Result]');
    my $transformed = Typist::Transform->aliases_to_vars(
        $type, +{ Elem => 1, Result => 1 }
    );
    my @fv = sort $transformed->free_vars;
    is_deeply \@fv, [qw(Elem Result)], 'free_vars returns multi-char names';
};

done_testing;
