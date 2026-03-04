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
            eq  => '(T, T) -> Bool',
            neq => '(T, T) -> Bool',
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
            eq  => '(T, T) -> Bool',
            neq => '(T, T) -> Bool',
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
        methods => +{ show => '(T) -> Str' },
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
        methods => +{ compare => '(T, T) -> Int' },
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
            eq  => '(T, T) -> Bool',
            neq => '(T, T) -> Bool',
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

# ── Superclass parsing ──────────────────────────

subtest 'superclass constraint parsing' => sub {
    my $def = Typist::TypeClass->new_class(
        name => 'Ord',
        var  => 'T: Eq',
        methods => +{ compare => '(T, T) -> Int' },
    );

    is $def->name, 'Ord', 'class name';
    is $def->var, 'T', 'type variable extracted';
    is_deeply [$def->supers], ['Eq'], 'single superclass parsed';
    ok !$def->var_kind_str, 'no HKT kind';
};

subtest 'multiple superclass constraints' => sub {
    my $def = Typist::TypeClass->new_class(
        name => 'Printable',
        var  => 'T: Show + Eq',
        methods => +{ display => '(T) -> Str' },
    );

    is $def->var, 'T', 'type variable extracted';
    is_deeply [$def->supers], ['Show', 'Eq'], 'multiple superclasses parsed';
};

subtest 'HKT kind not confused with superclass' => sub {
    my $def = Typist::TypeClass->new_class(
        name => 'Functor',
        var  => 'F: * -> *',
        methods => +{},
    );

    is $def->var, 'F', 'type variable';
    is $def->var_kind_str, '* -> *', 'HKT kind preserved';
    is_deeply [$def->supers], [], 'no superclasses';
};

# ── Superclass instance validation ──────────────

subtest 'superclass instance check passes when super instance exists' => sub {
    Typist::Registry->reset;

    my $eq_def = Typist::TypeClass->new_class(
        name => 'Eq', var => 'T',
        methods => +{ eq => '(T, T) -> Bool' },
    );
    Typist::Registry->register_typeclass('Eq', $eq_def);

    my $eq_inst = Typist::TypeClass->new_instance(
        class => 'Eq', type_expr => 'Int',
        methods => +{ eq => sub ($a, $b) { $a == $b ? 1 : 0 } },
    );
    Typist::Registry->register_instance('Eq', 'Int', $eq_inst);

    my $ord_def = Typist::TypeClass->new_class(
        name => 'Ord', var => 'T: Eq',
        methods => +{ compare => '(T, T) -> Int' },
    );
    Typist::Registry->register_typeclass('Ord', $ord_def);

    eval { $ord_def->check_superclass_instances('Int', 'Typist::Registry') };
    ok !$@, 'superclass check passes with Eq instance for Int';
};

subtest 'superclass instance check fails when super instance missing' => sub {
    Typist::Registry->reset;

    my $eq_def = Typist::TypeClass->new_class(
        name => 'Eq', var => 'T',
        methods => +{ eq => '(T, T) -> Bool' },
    );
    Typist::Registry->register_typeclass('Eq', $eq_def);
    # No Eq instance for Str registered

    my $ord_def = Typist::TypeClass->new_class(
        name => 'Ord', var => 'T: Eq',
        methods => +{ compare => '(T, T) -> Int' },
    );

    eval { $ord_def->check_superclass_instances('Str', 'Typist::Registry') };
    like $@, qr/requires superclass instance Eq/, 'dies when superclass instance missing';
};

# ── Multi-parameter typeclass definition ────────

subtest 'define multi-param typeclass' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Convertible',
        var     => 'T, U',
        methods => +{
            convert => '(T) -> U',
        },
    );

    is $def->name, 'Convertible', 'multi-param class name';
    is $def->var, 'T', 'var returns first variable (backward compat)';
    is_deeply [$def->var_names], ['T', 'U'], 'var_names returns all variables';
    is $def->arity, 2, 'arity is 2';
    ok $def->is_multi_param, 'is_multi_param returns true';
    is_deeply [sort $def->method_names], ['convert'], 'method names';

    Typist::Registry->register_typeclass('Convertible', $def);
    my $looked = Typist::Registry->lookup_typeclass('Convertible');
    ok $looked, 'lookup multi-param typeclass';
    is $looked->arity, 2, 'retrieved typeclass has arity 2';
};

# ── Single-param backward compat for arity ──────

subtest 'single-param arity and is_multi_param' => sub {
    my $def = Typist::TypeClass->new_class(
        name    => 'Show',
        var     => 'T',
        methods => +{ show => '(T) -> Str' },
    );

    is $def->arity, 1, 'single-param arity is 1';
    ok !$def->is_multi_param, 'single-param is_multi_param returns false';
    is_deeply [$def->var_names], ['T'], 'var_names for single-param';
};

# ── Multi-parameter instance registration ────────

subtest 'register multi-param instance' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Convertible',
        var     => 'T, U',
        methods => +{ convert => '(T) -> U' },
    );
    Typist::Registry->register_typeclass('Convertible', $def);

    my $inst = Typist::TypeClass->new_instance(
        class     => 'Convertible',
        type_expr => 'Int, Str',
        methods   => +{
            convert => sub ($x) { "$x" },
        },
    );
    Typist::Registry->register_instance('Convertible', 'Int, Str', $inst);

    is $inst->type_expr, 'Int, Str', 'instance type_expr preserved';
    is_deeply [$inst->type_exprs], ['Int', 'Str'], 'type_exprs splits correctly';

    # Resolve with arrayref of types
    my $int_type = Typist::Parser->parse('Int');
    my $str_type = Typist::Parser->parse('Str');
    my $resolved = Typist::Registry->resolve_instance('Convertible', [$int_type, $str_type]);
    ok $resolved, 'resolved multi-param instance for [Int, Str]';
    is $resolved->type_expr, 'Int, Str', 'resolved instance type_expr';

    # Test method works
    my $convert_fn = $resolved->get_method('convert');
    is $convert_fn->(42), '42', 'convert(42) returns "42"';
};

# ── Multi-parameter: no matching instance ─────────

subtest 'multi-param no matching instance' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Convertible',
        var     => 'T, U',
        methods => +{ convert => '(T) -> U' },
    );
    Typist::Registry->register_typeclass('Convertible', $def);

    my $inst = Typist::TypeClass->new_instance(
        class     => 'Convertible',
        type_expr => 'Int, Str',
        methods   => +{ convert => sub ($x) { "$x" } },
    );
    Typist::Registry->register_instance('Convertible', 'Int, Str', $inst);

    # Try resolving with wrong types
    my $str_type = Typist::Parser->parse('Str');
    my $int_type = Typist::Parser->parse('Int');
    my $resolved = Typist::Registry->resolve_instance('Convertible', [$str_type, $int_type]);
    ok !$resolved, 'no instance for [Str, Int]';
};

# ── Multi-parameter: multiple instances ───────────

subtest 'multi-param multiple instances' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Convertible',
        var     => 'T, U',
        methods => +{ convert => '(T) -> U' },
    );
    Typist::Registry->register_typeclass('Convertible', $def);

    # Instance: Int -> Str
    my $inst1 = Typist::TypeClass->new_instance(
        class     => 'Convertible',
        type_expr => 'Int, Str',
        methods   => +{ convert => sub ($x) { "$x" } },
    );
    Typist::Registry->register_instance('Convertible', 'Int, Str', $inst1);

    # Instance: Str -> Int
    my $inst2 = Typist::TypeClass->new_instance(
        class     => 'Convertible',
        type_expr => 'Str, Int',
        methods   => +{ convert => sub ($x) { length $x } },
    );
    Typist::Registry->register_instance('Convertible', 'Str, Int', $inst2);

    # Resolve Int -> Str
    my $int_type = Typist::Parser->parse('Int');
    my $str_type = Typist::Parser->parse('Str');
    my $r1 = Typist::Registry->resolve_instance('Convertible', [$int_type, $str_type]);
    ok $r1, 'resolved Int -> Str';
    is $r1->type_expr, 'Int, Str', 'correct instance for Int -> Str';
    is $r1->get_method('convert')->(42), '42', 'Int->Str convert works';

    # Resolve Str -> Int
    my $r2 = Typist::Registry->resolve_instance('Convertible', [$str_type, $int_type]);
    ok $r2, 'resolved Str -> Int';
    is $r2->type_expr, 'Str, Int', 'correct instance for Str -> Int';
    is $r2->get_method('convert')->("hello"), 5, 'Str->Int convert works';
};

# ── Multi-parameter: instance completeness ────────

subtest 'multi-param instance completeness' => sub {
    my $def = Typist::TypeClass->new_class(
        name    => 'Convertible',
        var     => 'T, U',
        methods => +{ convert => '(T) -> U' },
    );

    # Should pass: provides all methods
    eval {
        $def->check_instance_completeness('Int, Str', convert => sub ($x) { "$x" });
    };
    ok !$@, 'completeness check passes with all methods';

    # Should fail: missing method
    eval {
        $def->check_instance_completeness('Int, Str');
    };
    like $@, qr/missing method 'convert'/, 'completeness check fails when method missing';
};

# ── Multi-parameter: dispatch ─────────────────────

subtest 'multi-param dispatch' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Convertible',
        var     => 'T, U',
        methods => +{ convert => '(T) -> U' },
    );
    Typist::Registry->register_typeclass('Convertible', $def);

    my $inst = Typist::TypeClass->new_instance(
        class     => 'Convertible',
        type_expr => 'Int, Str',
        methods   => +{
            # Multi-param dispatch passes all args; method receives them all
            convert => sub { my ($x, $_witness) = @_; "num:$x" },
        },
    );
    Typist::Registry->register_instance('Convertible', 'Int, Str', $inst);

    # Manually create a multi-param dispatch function (as install_dispatch would)
    my $dispatch_convert = sub {
        my @args = @_;
        my @arg_types = map { Typist::Inference->infer_value($args[$_]) } 0 .. 1;
        my $inst = Typist::Registry->resolve_instance('Convertible', \@arg_types)
            // die "no instance";
        $inst->get_method('convert')->(@args);
    };

    # Dispatch: first arg is Int (42), second arg is Str ("target") → resolves to Int,Str instance
    is $dispatch_convert->(42, "target"), 'num:42', 'multi-param dispatch works';
};

# ── Multi-parameter: resolve with subtype hierarchy ──

subtest 'multi-param resolve with subtype' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Convertible',
        var     => 'T, U',
        methods => +{ convert => '(T) -> U' },
    );
    Typist::Registry->register_typeclass('Convertible', $def);

    # Register instance for Num, Str
    my $inst = Typist::TypeClass->new_instance(
        class     => 'Convertible',
        type_expr => 'Num, Str',
        methods   => +{ convert => sub ($x) { "num:$x" } },
    );
    Typist::Registry->register_instance('Convertible', 'Num, Str', $inst);

    # Int <: Num, so [Int, Str] should resolve to the Num, Str instance
    my $int_type = Typist::Parser->parse('Int');
    my $str_type = Typist::Parser->parse('Str');
    my $resolved = Typist::Registry->resolve_instance('Convertible', [$int_type, $str_type]);
    ok $resolved, 'resolved multi-param via subtype hierarchy';
    is $resolved->type_expr, 'Num, Str', 'resolved to Num, Str instance';
};

# ── Three-parameter typeclass ─────────────────────

subtest 'three-param typeclass' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Triadic',
        var     => 'A, B, C',
        methods => +{ combine => '(A, B) -> C' },
    );

    is $def->arity, 3, 'arity is 3';
    ok $def->is_multi_param, 'three params is multi-param';
    is_deeply [$def->var_names], ['A', 'B', 'C'], 'three var names';

    Typist::Registry->register_typeclass('Triadic', $def);

    my $inst = Typist::TypeClass->new_instance(
        class     => 'Triadic',
        type_expr => 'Int, Int, Str',
        methods   => +{ combine => sub ($a, $b) { "$a+$b" } },
    );
    Typist::Registry->register_instance('Triadic', 'Int, Int, Str', $inst);

    my $int = Typist::Parser->parse('Int');
    my $str = Typist::Parser->parse('Str');
    my $resolved = Typist::Registry->resolve_instance('Triadic', [$int, $int, $str]);
    ok $resolved, 'resolved three-param instance';
    is $resolved->get_method('combine')->(3, 7), '3+7', 'three-param method works';
};

# ── Compound typeclass constraints in parse_generic_decl ───

subtest 'parse_generic_decl: multiple typeclass constraints' => sub {
    Typist::Registry->reset;

    # Register two typeclasses
    for my $tc_name (qw(Printable Ord)) {
        my $def = Typist::TypeClass->new_class(
            name    => $tc_name,
            var     => 'T',
            methods => +{},
        );
        Typist::Registry->register_typeclass($tc_name, $def);
    }

    require Typist::Attribute;
    my @gen = Typist::Attribute->parse_generic_decl('T: Printable + Ord');
    is scalar @gen, 1, 'one generic';
    is $gen[0]{name}, 'T', 'name is T';
    is_deeply $gen[0]{tc_constraints}, [qw(Printable Ord)], 'both tc_constraints';
    ok !$gen[0]{bound_expr}, 'no bound_expr';
};

subtest 'parse_generic_decl: mixed typeclass + bound' => sub {
    Typist::Registry->reset;

    my $def = Typist::TypeClass->new_class(
        name    => 'Show',
        var     => 'T',
        methods => +{},
    );
    Typist::Registry->register_typeclass('Show', $def);

    require Typist::Attribute;
    my @gen = Typist::Attribute->parse_generic_decl('T: Show + Num');
    is scalar @gen, 1, 'one generic';
    is $gen[0]{name}, 'T', 'name is T';
    is_deeply $gen[0]{tc_constraints}, ['Show'], 'tc_constraints has Show';
    is $gen[0]{bound_expr}, 'Num', 'bound_expr has Num';
};

# ── Struct runtime inference ───────────────────

subtest 'infer_value: blessed struct recognized' => sub {
    Typist::Registry->reset;

    # Simulate a struct type registered in the registry
    my $struct_type = Typist::Parser->parse('{ name => Str }');
    Typist::Registry->register_type('Point', $struct_type);

    # Create a blessed struct instance
    my $instance = bless {
        name => 'test',
    }, 'Typist::Struct::Point';

    # Give it _typist_struct_meta
    no strict 'refs';
    *{'Typist::Struct::Point::_typist_struct_meta'} = sub {
        +{ name => 'Point', required => +{ name => 'Str' }, optional => +{} };
    };

    my $inferred = Typist::Inference->infer_value($instance);
    ok $inferred, 'inferred a type';
    is $inferred->to_string, $struct_type->to_string, 'inferred struct type matches';
};

done_testing;
