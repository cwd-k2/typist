use v5.40;
use Test::More;
use lib 'lib';
use Typist::TypeClass;
use Typist::Registry;
use Typist::Parser;
use Typist::Inference;

# ── TypeClass definition ────────────────────────

subtest 'define typeclass' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Eq',
        var     => 'T',
        methods => +{
            eq  => 'CodeRef[T, T -> Bool]',
            neq => 'CodeRef[T, T -> Bool]',
        },
    );

    is $def->name, 'Eq', 'class name';
    is $def->var, 'T', 'type variable';
    is_deeply [sort $def->method_names], [qw(eq neq)], 'method names';

    Typist::Registry->register_typeclass('Eq', $def);
    my $looked = Typist::Registry->lookup_typeclass('Eq');
    ok $looked, 'lookup_typeclass';
    is $looked->name, 'Eq', 'retrieved class name';
};

# ── Instance registration ───────────────────────

subtest 'register instance' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Eq',
        var     => 'T',
        methods => +{
            eq  => 'CodeRef[T, T -> Bool]',
            neq => 'CodeRef[T, T -> Bool]',
        },
    );
    Typist::Registry->register_typeclass('Eq', $def);

    my $inst = Typist::TypeClass->new_instance(
        class     => 'Eq',
        type_expr => 'Int',
        methods   => +{
            eq  => sub ($a, $b) { $a == $b ? 1 : 0 },
            neq => sub ($a, $b) { $a != $b ? 1 : 0 },
        },
    );
    Typist::Registry->register_instance('Eq', 'Int', $inst);

    # Resolve for Int
    my $int_type = Typist::Parser->parse('Int');
    my $resolved = Typist::Registry->resolve_instance('Eq', $int_type);
    ok $resolved, 'resolved instance for Int';
    is $resolved->type_expr, 'Int', 'instance type_expr';

    # Test dispatched methods
    my $eq_fn = $resolved->get_method('eq');
    ok $eq_fn->(1, 1), 'eq(1, 1) = true';
    ok !$eq_fn->(1, 2), 'eq(1, 2) = false';
};

# ── Instance resolution with hierarchy ──────────

subtest 'resolve instance via hierarchy' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Show',
        var     => 'T',
        methods => +{ show => 'CodeRef[T -> Str]' },
    );
    Typist::Registry->register_typeclass('Show', $def);

    my $inst = Typist::TypeClass->new_instance(
        class     => 'Show',
        type_expr => 'Num',
        methods   => +{ show => sub ($v) { "$v" } },
    );
    Typist::Registry->register_instance('Show', 'Num', $inst);

    # Int <: Num, so Int should resolve to the Num instance
    my $int_type = Typist::Parser->parse('Int');
    my $resolved = Typist::Registry->resolve_instance('Show', $int_type);
    ok $resolved, 'resolved Show instance for Int via Num';
    is $resolved->type_expr, 'Num', 'resolved to Num instance';
};

# ── No instance ─────────────────────────────────

subtest 'no instance' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Ord',
        var     => 'T',
        methods => +{ compare => 'CodeRef[T, T -> Int]' },
    );
    Typist::Registry->register_typeclass('Ord', $def);

    my $str_type = Typist::Parser->parse('Str');
    my $resolved = Typist::Registry->resolve_instance('Ord', $str_type);
    ok !$resolved, 'no Ord instance for Str';
};

# ── Instance completeness ────────────────────────

subtest 'dispatch function' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Eq',
        var     => 'T',
        methods => +{
            eq  => 'CodeRef[T, T -> Bool]',
            neq => 'CodeRef[T, T -> Bool]',
        },
    );
    Typist::Registry->register_typeclass('Eq', $def);

    my $inst = Typist::TypeClass->new_instance(
        class     => 'Eq',
        type_expr => 'Int',
        methods   => +{
            eq  => sub ($a, $b) { $a == $b ? 1 : 0 },
            neq => sub ($a, $b) { $a != $b ? 1 : 0 },
        },
    );
    Typist::Registry->register_instance('Eq', 'Int', $inst);

    # Manually create a dispatch function (as Typist.pm would)
    my $dispatch_eq = sub {
        my @args = @_;
        my $arg_type = Typist::Inference->infer_value($args[0]);
        my $inst = Typist::Registry->resolve_instance('Eq', $arg_type)
            // die "no instance";
        $inst->get_method('eq')->(@args);
    };

    ok  $dispatch_eq->(1, 1),  'dispatch eq(1, 1)';
    ok !$dispatch_eq->(1, 2),  'dispatch eq(1, 2)';
};

done_testing;
