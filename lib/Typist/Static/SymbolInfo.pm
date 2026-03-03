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

=head1 NAME

Typist::Static::SymbolInfo - Factory functions for symbol hashref construction

=head1 DESCRIPTION

Provides named constructors for the symbol hashrefs used throughout the static
analysis pipeline and LSP layer. Each factory sets the C<kind> field and
supplies sensible defaults for optional entries.

=head2 sym_function

    my $sym = sym_function(name => 'greet', returns_expr => 'Str', line => 5, col => 1);

Builds a C<function> symbol. Optional flags: C<unannotated>, C<declared>,
C<constructor>, C<struct_constructor>, C<builtin>, C<typist_builtin>,
C<protocol_transitions>. C<params_expr> and C<generics> default to empty
arrayrefs.

=head2 sym_parameter

    my $sym = sym_parameter(name => '$x', type => $int, fn_name => 'add', line => 3, col => 5);

Builds a C<parameter> symbol bound to its enclosing function. Optional:
C<unannotated>, C<scope_start>, C<scope_end>.

=head2 sym_variable

    my $sym = sym_variable(name => '$total', type => $int, line => 10, col => 5);

Builds a C<variable> symbol. C<inferred> defaults to C<0>. Optional:
C<unknown>, C<narrowed>, C<scope_start>, C<scope_end>.

=head2 sym_typedef

    my $sym = sym_typedef(name => 'UserId', type => $str, line => 1, col => 1);

Builds a C<typedef> symbol representing a type alias.

=head2 sym_newtype

    my $sym = sym_newtype(name => 'Email', type => $str, line => 2, col => 1);

Builds a C<newtype> symbol representing a nominal wrapper type.

=head2 sym_effect

    my $sym = sym_effect(name => 'Console', op_names => ['writeLine'], line => 4, col => 1);

Builds an C<effect> symbol. C<op_names> defaults to C<[]>, C<operations> to
C<+{}>. Optional: C<protocol>, C<states>.

=head2 sym_typeclass

    my $sym = sym_typeclass(name => 'Show', var_spec => 'T', method_names => ['show'], line => 6, col => 1);

Builds a C<typeclass> symbol. C<method_names> defaults to C<[]>, C<methods>
to C<+{}>.

=head2 sym_datatype

    my $sym = sym_datatype(name => 'Shape', type => $dt, variants => ['Circle', 'Rect'], line => 8, col => 1);

Builds a C<datatype> symbol for an algebraic data type. C<variants> and
C<type_params> default to empty arrayrefs.

=head2 sym_struct

    my $sym = sym_struct(name => 'Person', fields => [{ name => 'name', type_expr => 'Str' }], line => 9, col => 1);

Builds a C<struct> symbol. C<fields> defaults to C<[]>.

=head2 sym_field

    my $sym = sym_field(name => 'age', type => $int, struct_name => 'Person');

Builds a C<field> symbol belonging to a struct. C<optional> defaults to C<0>.

=head2 sym_method

    my $sym = sym_method(name => 'greet', struct_name => 'Person', returns => $str);

Builds a C<method> symbol associated with a struct, recording the return type.

=cut
