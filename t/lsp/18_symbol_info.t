use v5.40;
use Test::More;
use lib 'lib';

use Typist::LSP::SymbolInfo qw(
    sym_function sym_parameter sym_variable sym_typedef sym_newtype
    sym_effect sym_typeclass sym_datatype sym_struct sym_field sym_method
);

# ── sym_function ─────────────────────────────────

subtest 'sym_function sets kind and defaults' => sub {
    my $s = sym_function(name => 'add', line => 5, col => 1);
    is $s->{kind}, 'function', 'kind is function';
    is $s->{name}, 'add', 'name set';
    is_deeply $s->{params_expr}, [], 'params_expr defaults to []';
    is_deeply $s->{generics}, [], 'generics defaults to []';
    is $s->{returns_expr}, undef, 'returns_expr defaults to undef';
    is $s->{eff_expr}, undef, 'eff_expr defaults to undef';
    ok !exists $s->{unannotated}, 'no unannotated flag by default';
    ok !exists $s->{constructor}, 'no constructor flag by default';
};

subtest 'sym_function with flags' => sub {
    my $s = sym_function(
        name => 'f', unannotated => 1, constructor => 1,
        struct_constructor => 1, declared => 1,
    );
    ok $s->{unannotated}, 'unannotated set';
    ok $s->{constructor}, 'constructor set';
    ok $s->{struct_constructor}, 'struct_constructor set';
    ok $s->{declared}, 'declared set';
};

# ── sym_parameter ────────────────────────────────

subtest 'sym_parameter sets kind and required fields' => sub {
    my $s = sym_parameter(name => '$x', type => 'Int', fn_name => 'add', line => 3, col => 5);
    is $s->{kind}, 'parameter', 'kind is parameter';
    is $s->{name}, '$x', 'name set';
    is $s->{type}, 'Int', 'type set';
    is $s->{fn_name}, 'add', 'fn_name set';
};

subtest 'sym_parameter with scope' => sub {
    my $s = sym_parameter(
        name => '$y', type => 'Str', fn_name => 'greet',
        scope_start => 10, scope_end => 20,
    );
    is $s->{scope_start}, 10, 'scope_start set';
    is $s->{scope_end}, 20, 'scope_end set';
};

# ── sym_variable ─────────────────────────────────

subtest 'sym_variable sets kind and defaults' => sub {
    my $s = sym_variable(name => '$x', type => 'Int', line => 1, col => 1);
    is $s->{kind}, 'variable', 'kind is variable';
    is $s->{inferred}, 0, 'inferred defaults to 0';
    ok !exists $s->{unknown}, 'no unknown by default';
    ok !exists $s->{narrowed}, 'no narrowed by default';
};

subtest 'sym_variable with flags' => sub {
    my $s = sym_variable(name => '$x', type => 'Any', inferred => 1, unknown => 1);
    is $s->{inferred}, 1, 'inferred set';
    ok $s->{unknown}, 'unknown set';
};

# ── sym_typedef ──────────────────────────────────

subtest 'sym_typedef sets kind' => sub {
    my $s = sym_typedef(name => 'Name', type => 'Str', line => 2, col => 1);
    is $s->{kind}, 'typedef', 'kind is typedef';
    is $s->{name}, 'Name', 'name set';
    is $s->{type}, 'Str', 'type set';
};

# ── sym_newtype ──────────────────────────────────

subtest 'sym_newtype sets kind' => sub {
    my $s = sym_newtype(name => 'UserId', type => 'Int', line => 3, col => 1);
    is $s->{kind}, 'newtype', 'kind is newtype';
};

# ── sym_effect ───────────────────────────────────

subtest 'sym_effect sets kind and defaults' => sub {
    my $s = sym_effect(name => 'Console', op_names => ['writeLine'], line => 1, col => 1);
    is $s->{kind}, 'effect', 'kind is effect';
    is_deeply $s->{op_names}, ['writeLine'], 'op_names set';
    is_deeply $s->{operations}, +{}, 'operations defaults to {}';
    ok !exists $s->{protocol}, 'no protocol by default';
};

# ── sym_typeclass ────────────────────────────────

subtest 'sym_typeclass sets kind and defaults' => sub {
    my $s = sym_typeclass(name => 'Show', var_spec => 'T', line => 1, col => 1);
    is $s->{kind}, 'typeclass', 'kind is typeclass';
    is $s->{var_spec}, 'T', 'var_spec set';
    is_deeply $s->{method_names}, [], 'method_names defaults to []';
    is_deeply $s->{methods}, +{}, 'methods defaults to {}';
};

# ── sym_datatype ─────────────────────────────────

subtest 'sym_datatype sets kind and defaults' => sub {
    my $s = sym_datatype(name => 'Color', type => 'Red | Green | Blue', line => 1, col => 1);
    is $s->{kind}, 'datatype', 'kind is datatype';
    is_deeply $s->{variants}, [], 'variants defaults to []';
    is_deeply $s->{type_params}, [], 'type_params defaults to []';
};

# ── sym_struct ───────────────────────────────────

subtest 'sym_struct sets kind and defaults' => sub {
    my $s = sym_struct(name => 'Point', fields => ['x: Int', 'y: Int'], line => 1, col => 1);
    is $s->{kind}, 'struct', 'kind is struct';
    is_deeply $s->{fields}, ['x: Int', 'y: Int'], 'fields set';
};

# ── sym_field ────────────────────────────────────

subtest 'sym_field sets kind' => sub {
    my $s = sym_field(name => 'x', type => 'Int', struct_name => 'Point', optional => 0);
    is $s->{kind}, 'field', 'kind is field';
    is $s->{struct_name}, 'Point', 'struct_name set';
    is $s->{optional}, 0, 'optional set';
};

# ── sym_method ───────────────────────────────────

subtest 'sym_method sets kind' => sub {
    my $s = sym_method(name => 'with', struct_name => 'Point', returns => 'Point');
    is $s->{kind}, 'method', 'kind is method';
    is $s->{struct_name}, 'Point', 'struct_name set';
    is $s->{returns}, 'Point', 'returns set';
};

done_testing;
