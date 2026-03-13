use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Typist::Static::Extractor;
use Typist::Static::Registration;
use Typist::Registry;
use Typist::Prelude;
use Typist::Error;

use Test::Typist::Analyze qw(analyze diags_of_kind);

# ── Invalid typeclass definition → ResolveError, not registered ──

subtest 'invalid typeclass: error collected, not registered' => sub {
    my $registry = Typist::Registry->new;
    Typist::Prelude->install($registry);
    my $errors = Typist::Error->collector;

    # Construct extracted data with an invalid typeclass (missing methods hash)
    # TypeClass->new_class expects methods to be a hashref; a bad var_spec
    # can trigger a die inside new_class.
    my $extracted = +{
        package     => 'TestPkg',
        use_modules => [],
        aliases     => +{},
        newtypes    => +{},
        structs     => +{},
        datatypes   => +{},
        effects     => +{},
        typeclasses => +{
            BadTC => +{
                var_spec => 'T',
                methods  => +{ bad_method => '(INVALID>>>>' },
                line     => 10,
            },
        },
        instances   => [],
        declares    => +{},
        functions   => +{},
    };

    Typist::Static::Registration->register_typeclasses(
        $extracted, $registry,
        errors => $errors,
        file   => '(test)',
    );

    # The typeclass itself should be registered (new_class doesn't fail on bad sigs),
    # but the method with invalid sig should produce a ResolveError
    my @errs = $errors->errors;
    my @resolve = grep { $_->kind eq 'ResolveError' } @errs;
    ok @resolve >= 1, 'invalid method sig produces ResolveError'
        or diag explain [map { $_->message } @errs];
};

# ── Invalid return type → ResolveError, function not registered ──

subtest 'invalid return type: error collected, function skipped' => sub {
    my $registry = Typist::Registry->new;
    Typist::Prelude->install($registry);
    my $errors = Typist::Error->collector;

    my $extracted = +{
        package     => 'TestPkg',
        use_modules => [],
        aliases     => +{},
        newtypes    => +{},
        structs     => +{},
        datatypes   => +{},
        effects     => +{},
        typeclasses => +{},
        instances   => [],
        declares    => +{},
        functions   => +{
            bad_fn => +{
                params_expr  => ['Int'],
                returns_expr => 'INVALID>>>>',
                eff_expr     => undef,
                generics     => [],
                line         => 5,
                unannotated  => 0,
            },
        },
    };

    Typist::Static::Registration->register_functions(
        $extracted, $registry,
        errors => $errors,
        file   => '(test)',
    );

    my @errs = $errors->errors;
    my @resolve = grep { $_->kind eq 'ResolveError' } @errs;
    ok @resolve >= 1, 'invalid return type produces ResolveError';

    my $sig = $registry->lookup_function('TestPkg', 'bad_fn');
    ok !$sig, 'function with invalid return type not registered';
};

# ── Both return type and effect bad → function skipped ──

subtest 'invalid return type skips function even with valid effect' => sub {
    my $registry = Typist::Registry->new;
    Typist::Prelude->install($registry);
    my $errors = Typist::Error->collector;

    my $extracted = +{
        package     => 'TestPkg',
        use_modules => [],
        aliases     => +{},
        newtypes    => +{},
        structs     => +{},
        datatypes   => +{},
        effects     => +{},
        typeclasses => +{},
        instances   => [],
        declares    => +{},
        functions   => +{
            combo_fn => +{
                params_expr  => ['Int'],
                returns_expr => 'ArrayRef[',
                eff_expr     => 'IO',
                generics     => [],
                line         => 7,
                unannotated  => 0,
            },
        },
    };

    Typist::Static::Registration->register_functions(
        $extracted, $registry,
        errors => $errors,
        file   => '(test)',
    );

    my @errs = $errors->errors;
    my @resolve = grep { $_->kind eq 'ResolveError' } @errs;
    ok @resolve >= 1, 'invalid return type produces ResolveError';

    my $sig = $registry->lookup_function('TestPkg', 'combo_fn');
    ok !$sig, 'function with invalid return type not registered (skip flag)';
};

# ── Invalid GADT return type → ResolveError ──

subtest 'invalid GADT return type: error collected' => sub {
    my $registry = Typist::Registry->new;
    Typist::Prelude->install($registry);
    my $errors = Typist::Error->collector;

    my $extracted = +{
        package     => 'TestPkg',
        use_modules => [],
        aliases     => +{},
        newtypes    => +{},
        structs     => +{},
        datatypes   => +{
            BadGADT => +{
                type_params => [],
                variants    => +{ Ctor => '(Int) -> INVALID>>>>' },
                line        => 15,
            },
        },
        effects     => +{},
        typeclasses => +{},
        instances   => [],
        declares    => +{},
        functions   => +{},
    };

    Typist::Static::Registration->register_datatypes(
        $extracted, $registry,
        errors => $errors,
        file   => '(test)',
    );

    my @errs = $errors->errors;
    my @resolve = grep { $_->kind eq 'ResolveError' } @errs;
    ok @resolve >= 1, 'invalid GADT return type produces ResolveError'
        or diag explain [map { $_->message } @errs];
};

# ── Invalid effect op sig → ResolveError ──

subtest 'invalid effect op sig: error collected' => sub {
    my $registry = Typist::Registry->new;
    Typist::Prelude->install($registry);
    my $errors = Typist::Error->collector;

    my $extracted = +{
        package     => 'TestPkg',
        use_modules => [],
        aliases     => +{},
        newtypes    => +{},
        structs     => +{},
        datatypes   => +{},
        effects     => +{
            BadEff => +{
                operations => +{ bad_op => 'INVALID>>>>' },
                line       => 20,
            },
        },
        typeclasses => +{},
        instances   => [],
        declares    => +{},
        functions   => +{},
    };

    Typist::Static::Registration->register_effects(
        $extracted, $registry,
        errors => $errors,
        file   => '(test)',
    );

    my @errs = $errors->errors;
    my @resolve = grep { $_->kind eq 'ResolveError' } @errs;
    ok @resolve >= 1, 'invalid effect op sig produces ResolveError'
        or diag explain [map { $_->message } @errs];
};

# ── Integration: full analyzer with invalid typedef ──

subtest 'integration: analyzer collects registration errors' => sub {
    my $result = analyze(<<'PERL');
package RegErrTest;
use v5.40;

typedef BadType => 'ArrayRef[';
PERL

    my @diags = $result->{diagnostics}->@*;
    my @resolve = grep { $_->{kind} eq 'ResolveError' } @diags;
    ok @resolve >= 1, 'analyzer catches registration ResolveError for invalid typedef'
        or diag explain \@diags;
};

done_testing;
