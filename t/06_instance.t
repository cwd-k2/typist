use v5.40;
use Test::More;
use lib 'lib';

use Typist::Registry;
use Typist::Error;
use Typist::Error::Global;
use Typist::Static::Checker;
use Typist::Parser;

# ── Registry instance isolation ──────────────────

subtest 'Registry instances are isolated' => sub {
    my $r1 = Typist::Registry->new;
    my $r2 = Typist::Registry->new;

    $r1->define_alias('Name', 'Str');
    $r2->define_alias('Age', 'Int');

    ok  $r1->has_alias('Name'), 'r1 has Name';
    ok !$r1->has_alias('Age'),  'r1 does not have Age';
    ok !$r2->has_alias('Name'), 'r2 does not have Name';
    ok  $r2->has_alias('Age'),  'r2 has Age';
};

subtest 'Registry instance lookup resolves types' => sub {
    my $r = Typist::Registry->new;
    $r->define_alias('Email', 'Str');

    my $type = $r->lookup_type('Email');
    ok $type, 'resolved Email';
    ok $type->is_atom, 'Email resolves to Atom';
    is $type->name, 'Str', 'Email resolves to Str';
};

subtest 'Registry instance cycle detection' => sub {
    my $r = Typist::Registry->new;
    $r->define_alias('Foo', 'Bar');
    $r->define_alias('Bar', 'Foo');

    eval { $r->lookup_type('Foo') };
    like $@, qr/cycle/, 'detected alias cycle';
};

subtest 'Registry instance functions' => sub {
    my $r = Typist::Registry->new;
    $r->register_function('Pkg', 'foo', { params => [], returns => undef });

    my $sig = $r->lookup_function('Pkg', 'foo');
    ok $sig, 'registered function found';

    my %fns = $r->all_functions;
    ok exists $fns{'Pkg::foo'}, 'all_functions includes Pkg::foo';
};

# ── Registry merge ───────────────────────────────

subtest 'Registry merge combines aliases' => sub {
    my $r1 = Typist::Registry->new;
    my $r2 = Typist::Registry->new;

    $r1->define_alias('Name', 'Str');
    $r2->define_alias('Age', 'Int');
    $r2->define_alias('Name', 'Int');  # conflict — r1 should win

    $r1->merge($r2);

    ok $r1->has_alias('Name'), 'has Name';
    ok $r1->has_alias('Age'),  'has Age (merged)';

    # r1's original definition takes precedence
    my $name_type = $r1->lookup_type('Name');
    is $name_type->name, 'Str', 'merge preserves existing alias';
};

subtest 'Registry merge combines functions' => sub {
    my $r1 = Typist::Registry->new;
    my $r2 = Typist::Registry->new;

    my $params = [Typist::Parser->parse('Int')];
    my $returns = Typist::Parser->parse('Str');

    $r1->register_function('A', 'f', { params => $params, returns => $returns });
    $r2->register_function('B', 'g', { params => $params, returns => $returns });

    $r1->merge($r2);

    ok $r1->lookup_function('A', 'f'), 'f preserved';
    ok $r1->lookup_function('B', 'g'), 'g merged';
};

# ── Error collector instance ─────────────────────

subtest 'Error collector is isolated from global' => sub {
    Typist::Error::Global->reset;
    my $c = Typist::Error->collector;

    $c->collect(kind => 'TestError', message => 'test msg', file => 'test.pm', line => 1);

    ok  $c->has_errors,                    'collector has errors';
    ok !Typist::Error::Global->has_errors, 'global is clean';

    my @errs = $c->errors;
    is scalar @errs, 1, 'collector has 1 error';
    is $errs[0]->kind, 'TestError', 'error kind matches';
    is $errs[0]->message, 'test msg', 'error message matches';
};

subtest 'Error collector report' => sub {
    my $c = Typist::Error->collector;
    $c->collect(kind => 'A', message => 'first',  file => 'a.pm', line => 1);
    $c->collect(kind => 'B', message => 'second', file => 'b.pm', line => 2);

    my $report = $c->report;
    like $report, qr/2 type errors/, 'report shows count';
    like $report, qr/first/,  'report includes first error';
    like $report, qr/second/, 'report includes second error';
};

subtest 'Error collector reset' => sub {
    my $c = Typist::Error->collector;
    $c->collect(kind => 'X', message => 'x', file => 'x.pm', line => 1);
    ok $c->has_errors, 'has errors before reset';

    $c->reset;
    ok !$c->has_errors, 'clean after reset';
};

# ── Checker with injected dependencies ───────────

subtest 'Checker with instance registry and collector' => sub {
    my $reg = Typist::Registry->new;
    my $err = Typist::Error->collector;

    # Define a cycle
    $reg->define_alias('Loop1', 'Loop2');
    $reg->define_alias('Loop2', 'Loop1');

    my $checker = Typist::Static::Checker->new(registry => $reg, errors => $err);
    $checker->analyze;

    ok $err->has_errors, 'checker found errors';
    my @errs = $err->errors;
    ok((grep { $_->kind eq 'CycleError' } @errs), 'detected cycle error');
};

subtest 'Checker validates undeclared type vars' => sub {
    my $reg = Typist::Registry->new;
    my $err = Typist::Error->collector;

    # Register a function with undeclared type variable
    $reg->register_function('Test', 'bad_fn', {
        params   => [Typist::Parser->parse('T')],
        returns  => Typist::Parser->parse('T'),
        generics => [],  # T not declared
    });

    my $checker = Typist::Static::Checker->new(registry => $reg, errors => $err);
    $checker->analyze;

    ok $err->has_errors, 'checker found errors';
    my @errs = $err->errors;
    ok((grep { $_->kind eq 'UndeclaredTypeVar' } @errs), 'detected undeclared type var');
};

subtest 'Checker with clean registry produces no errors' => sub {
    my $reg = Typist::Registry->new;
    my $err = Typist::Error->collector;

    $reg->define_alias('Count', 'Int');
    $reg->register_function('Test', 'inc', {
        params   => [Typist::Parser->parse('Int')],
        returns  => Typist::Parser->parse('Int'),
        generics => [],
    });

    my $checker = Typist::Static::Checker->new(registry => $reg, errors => $err);
    $checker->analyze;

    ok !$err->has_errors, 'no errors for valid registry';
};

done_testing;
