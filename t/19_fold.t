use v5.40;
use Test::More;
use lib 'lib';

use Typist::Parser;
use Typist::Type::Fold;
use Typist::Type::Var;
use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Func;
use Typist::Type::Struct;
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
    my $type = Typist::Parser->parse_annotation('(Int) -> Str ! Console');
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
    ok $mapped->is_struct, 'result is Struct';
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

done_testing;
