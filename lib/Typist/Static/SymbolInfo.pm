package Typist::Static::SymbolInfo;
use v5.40;

our $VERSION = '0.01';

use Exporter 'import';
our @EXPORT_OK = qw(
    sym_function sym_parameter sym_variable sym_typedef sym_newtype
    sym_effect sym_typeclass sym_datatype sym_struct sym_field sym_method
);

# ── Factory Functions ───────────────────────────
#
# Each factory sets `kind` and provides defaults for optional fields.
# Required fields are accepted as named pairs; missing keys produce undef.

sub sym_function (%args) {
    +{
        kind         => 'function',
        name         => $args{name},
        params_expr  => $args{params_expr}  // [],
        returns_expr => $args{returns_expr},
        generics     => $args{generics}     // [],
        eff_expr     => $args{eff_expr},
        line         => $args{line},
        col          => $args{col},
        # Optional flags
        ($args{unannotated}        ? (unannotated        => 1) : ()),
        ($args{declared}           ? (declared            => 1) : ()),
        ($args{constructor}        ? (constructor         => 1) : ()),
        ($args{struct_constructor} ? (struct_constructor  => 1) : ()),
        ($args{builtin}            ? (builtin             => 1) : ()),
        ($args{typist_builtin}     ? (typist_builtin      => 1) : ()),
        (defined $args{protocol_transitions} ? (protocol_transitions => $args{protocol_transitions}) : ()),
    };
}

sub sym_parameter (%args) {
    +{
        kind        => 'parameter',
        name        => $args{name},
        type        => $args{type},
        fn_name     => $args{fn_name},
        line        => $args{line},
        col         => $args{col},
        ($args{unannotated} ? (unannotated => 1) : ()),
        (defined $args{scope_start} ? (scope_start => $args{scope_start}) : ()),
        (defined $args{scope_end}   ? (scope_end   => $args{scope_end})   : ()),
    };
}

sub sym_variable (%args) {
    +{
        kind     => 'variable',
        name     => $args{name},
        type     => $args{type},
        inferred => $args{inferred} // 0,
        ($args{unknown}  ? (unknown  => 1) : ()),
        ($args{narrowed} ? (narrowed => 1) : ()),
        line     => $args{line},
        col      => $args{col},
        (defined $args{scope_start} ? (scope_start => $args{scope_start}) : ()),
        (defined $args{scope_end}   ? (scope_end   => $args{scope_end})   : ()),
    };
}

sub sym_typedef (%args) {
    +{
        kind => 'typedef',
        name => $args{name},
        type => $args{type},
        line => $args{line},
        col  => $args{col},
    };
}

sub sym_newtype (%args) {
    +{
        kind => 'newtype',
        name => $args{name},
        type => $args{type},
        line => $args{line},
        col  => $args{col},
    };
}

sub sym_effect (%args) {
    +{
        kind       => 'effect',
        name       => $args{name},
        op_names   => $args{op_names}   // [],
        operations => $args{operations} // +{},
        line       => $args{line},
        col        => $args{col},
        (defined $args{protocol} ? (protocol => $args{protocol}) : ()),
        (defined $args{states}   ? (states   => $args{states})   : ()),
    };
}

sub sym_typeclass (%args) {
    +{
        kind         => 'typeclass',
        name         => $args{name},
        var_spec     => $args{var_spec},
        method_names => $args{method_names} // [],
        methods      => $args{methods}      // +{},
        line         => $args{line},
        col          => $args{col},
    };
}

sub sym_datatype (%args) {
    +{
        kind        => 'datatype',
        name        => $args{name},
        type        => $args{type},
        variants    => $args{variants}    // [],
        type_params => $args{type_params} // [],
        line        => $args{line},
        col         => $args{col},
    };
}

sub sym_struct (%args) {
    +{
        kind   => 'struct',
        name   => $args{name},
        fields => $args{fields} // [],
        line   => $args{line},
        col    => $args{col},
    };
}

sub sym_field (%args) {
    +{
        kind        => 'field',
        name        => $args{name},
        type        => $args{type},
        struct_name => $args{struct_name},
        optional    => $args{optional} // 0,
    };
}

sub sym_method (%args) {
    +{
        kind        => 'method',
        name        => $args{name},
        struct_name => $args{struct_name},
        returns     => $args{returns},
    };
}

1;
