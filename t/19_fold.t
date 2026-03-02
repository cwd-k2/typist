use v5.40;
use Test::More;
use lib 'lib';

use Typist::Parser;
use Typist::Type::Fold;
use Typist::Type::Var;
use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Func;
use Typist::Type::Record;
use Typist::Type::Union;

# ── map_type: identity ─────────────────────────

subtest 'map_type identity preserves all node types' => sub {
    my $identity = sub ($node) { $node };

    my @cases = (
        'Int',
        'ArrayRef[Int]',
        'Int | Str',
        'Int & Str',
        '{name => Str, age? => Int}',
        'Maybe[Str]',
    );

    for my $expr (@cases) {
        my $type = Typist::Parser->parse($expr);
        my $mapped = Typist::Type::Fold->map_type($type, $identity);
        ok $mapped->equals($type), "identity: $expr";
    }
};

# ── map_type: Alias → Var ──────────────────────

subtest 'map_type transforms Alias to Var' => sub {
    my %vars = (T => 1, U => 1);
    my $cb = sub ($node) {
        return Typist::Type::Var->new($node->alias_name)
            if $node->is_alias && $vars{$node->alias_name};
        $node;
    };

    # ArrayRef[T] → T should become Var
    my $type = Typist::Parser->parse('ArrayRef[T]');
    my $mapped = Typist::Type::Fold->map_type($type, $cb);
    ok $mapped->is_param, 'result is Param';
    my @p = $mapped->params;
    ok $p[0]->is_var, 'inner T is now Var';
    is $p[0]->name, 'T', 'Var name is T';
};

subtest 'map_type transforms nested Aliases' => sub {
    my %vars = (Elem => 1);
    my $cb = sub ($node) {
        return Typist::Type::Var->new($node->alias_name)
            if $node->is_alias && $vars{$node->alias_name};
        $node;
    };

    my $type = Typist::Parser->parse('HashRef[Str, ArrayRef[Elem]]');
    my $mapped = Typist::Type::Fold->map_type($type, $cb);
    my @outer = $mapped->params;
    ok $outer[0]->is_atom, 'Str stays Atom';
    ok $outer[1]->is_param, 'ArrayRef stays Param';
    my @inner = $outer[1]->params;
    ok $inner[0]->is_var, 'Elem is now Var';
    is $inner[0]->name, 'Elem', 'Var name is Elem';
};

# ── map_type: Func with effects ─────────────────

subtest 'map_type preserves Func effects' => sub {
    my $type = Typist::Parser->parse_annotation('(Int) -> Str !Eff(Console)');
    my $func = $type->{type};
    ok $func->is_func, 'parsed as Func';
    ok $func->effects, 'has effects';

    my $mapped = Typist::Type::Fold->map_type($func, sub ($n) { $n });
    ok $mapped->is_func, 'mapped is Func';
    ok $mapped->effects, 'mapped preserves effects';
    is $mapped->effects->to_string, $func->effects->to_string, 'effects match';
};

# ── map_type: Struct ────────────────────────────

subtest 'map_type transforms Struct field types' => sub {
    my $type = Typist::Parser->parse('{name => Str, value => Elem}');
    my $mapped = Typist::Type::Fold->map_type($type, sub ($node) {
        return Typist::Type::Atom->new('Int')
            if $node->is_alias && $node->alias_name eq 'Elem';
        $node;
    });
    ok $mapped->is_record, 'result is Struct';
    my %r = $mapped->required_fields;
    ok $r{name}->is_atom && $r{name}->name eq 'Str', 'name field unchanged';
    ok $r{value}->is_atom && $r{value}->name eq 'Int', 'value field transformed';
};

# ── walk: collect all names ─────────────────────

subtest 'walk visits all nodes' => sub {
    my $type = Typist::Parser->parse('ArrayRef[Int | Str]');
    my @visited;
    Typist::Type::Fold->walk($type, sub ($node) {
        push @visited, $node->to_string;
    });
    is scalar @visited, 4, 'visited 4 nodes (Param, Union, Atom, Atom)';
    is $visited[0], 'ArrayRef[Int | Str]', 'first is root';
};

subtest 'walk visits Func components' => sub {
    my $ann = Typist::Parser->parse_annotation('(Int, Str) -> Bool');
    my $func = $ann->{type};
    my @visited;
    Typist::Type::Fold->walk($func, sub ($node) {
        push @visited, $node->to_string;
    });
    # Func -> Int, Str (params) -> Bool (returns)
    is scalar @visited, 4, 'visited 4 nodes';
    is $visited[0], '(Int, Str) -> Bool', 'first is Func';
};

subtest 'walk visits Struct fields' => sub {
    my $type = Typist::Parser->parse('{x => Int, y => Str}');
    my @atoms;
    Typist::Type::Fold->walk($type, sub ($node) {
        push @atoms, $node->name if $node->is_atom;
    });
    is scalar @atoms, 2, 'found 2 atoms';
    my %names = map { $_ => 1 } @atoms;
    ok $names{Int} && $names{Str}, 'found Int and Str';
};

# ── map_type: Data preserves type_params/type_args ──

subtest 'map_type preserves Data type_params and type_args' => sub {
    require Typist::Type::Data;
    my $var_t = Typist::Type::Var->new('T');
    my $int   = Typist::Type::Atom->new('Int');
    my $dt = Typist::Type::Data->new('Option', +{
        Some => [$var_t],
        None => [],
    }, type_params => ['T'], type_args => [$int]);

    my $mapped = Typist::Type::Fold->map_type($dt, sub ($node) { $node });
    ok $mapped->is_data, 'mapped is data';
    is_deeply [$mapped->type_params], ['T'], 'type_params preserved';
    my @args = $mapped->type_args;
    is scalar @args, 1, 'one type_arg';
    ok $args[0]->is_atom && $args[0]->name eq 'Int', 'type_arg is Int';
};

subtest 'map_type transforms Data type_args' => sub {
    require Typist::Type::Data;
    my $var_t = Typist::Type::Var->new('T');
    my $int   = Typist::Type::Atom->new('Int');
    my $str   = Typist::Type::Atom->new('Str');
    my $dt = Typist::Type::Data->new('Box', +{
        Wrap => [$var_t],
    }, type_params => ['T'], type_args => [$var_t]);

    # Transform Var(T) -> Int in type_args
    my $mapped = Typist::Type::Fold->map_type($dt, sub ($node) {
        return $int if $node->is_var && $node->name eq 'T';
        $node;
    });
    my @args = $mapped->type_args;
    is scalar @args, 1, 'one type_arg';
    ok $args[0]->is_atom && $args[0]->name eq 'Int', 'type_arg transformed to Int';
};

subtest 'walk visits Data type_args' => sub {
    require Typist::Type::Data;
    my $var_t = Typist::Type::Var->new('T');
    my $int   = Typist::Type::Atom->new('Int');
    my $dt = Typist::Type::Data->new('Option', +{
        Some => [$var_t],
        None => [],
    }, type_params => ['T'], type_args => [$int]);

    my @visited;
    Typist::Type::Fold->walk($dt, sub ($node) {
        push @visited, $node->to_string;
    });
    ok((grep { $_ eq 'Int' } @visited), 'walk visited Int in type_args');
};

# ── GADT: Fold preserves/traverses return_types ──

subtest 'map_type preserves Data return_types (GADT)' => sub {
    require Typist::Type::Data;
    require Typist::Type::Param;
    my $var_a = Typist::Type::Var->new('A');
    my $int   = Typist::Type::Atom->new('Int');
    my $bool  = Typist::Type::Atom->new('Bool');

    my $dt = Typist::Type::Data->new('Expr', +{
        IntLit  => [$int],
        BoolLit => [$bool],
    },
        type_params  => ['A'],
        return_types => +{
            IntLit  => Typist::Type::Param->new('Expr', $int),
            BoolLit => Typist::Type::Param->new('Expr', $bool),
        },
    );

    my $mapped = Typist::Type::Fold->map_type($dt, sub ($node) { $node });
    ok $mapped->is_gadt, 'mapped is GADT';
    my $rt = $mapped->return_types;
    ok exists $rt->{IntLit},  'IntLit return_type preserved';
    ok exists $rt->{BoolLit}, 'BoolLit return_type preserved';
    ok $rt->{IntLit}->is_param, 'IntLit return is Param';
};

subtest 'map_type transforms return_types content' => sub {
    require Typist::Type::Data;
    require Typist::Type::Param;
    my $int  = Typist::Type::Atom->new('Int');
    my $str  = Typist::Type::Atom->new('Str');

    my $dt = Typist::Type::Data->new('Box', +{
        Wrap => [$int],
    },
        type_params  => ['T'],
        return_types => +{
            Wrap => Typist::Type::Param->new('Box', $int),
        },
    );

    # Transform Int -> Str inside return_types
    my $mapped = Typist::Type::Fold->map_type($dt, sub ($node) {
        return $str if $node->is_atom && $node->name eq 'Int';
        $node;
    });
    my $rt = $mapped->return_types;
    my @params = $rt->{Wrap}->params;
    ok $params[0]->is_atom && $params[0]->name eq 'Str', 'return_type content transformed';
};

subtest 'walk visits return_types (GADT)' => sub {
    require Typist::Type::Data;
    require Typist::Type::Param;
    my $int  = Typist::Type::Atom->new('Int');
    my $bool = Typist::Type::Atom->new('Bool');

    my $dt = Typist::Type::Data->new('Expr', +{
        IntLit => [$int],
    },
        type_params  => ['A'],
        return_types => +{
            IntLit => Typist::Type::Param->new('Expr', $bool),
        },
    );

    my @visited;
    Typist::Type::Fold->walk($dt, sub ($node) {
        push @visited, $node->to_string;
    });
    # Should visit Expr[Bool] (Param) inside return_types
    ok((grep { $_ eq 'Expr[Bool]' } @visited), 'walk visited Expr[Bool] in return_types');
    ok((grep { $_ eq 'Bool' } @visited), 'walk visited Bool inside return_type');
};

done_testing;
