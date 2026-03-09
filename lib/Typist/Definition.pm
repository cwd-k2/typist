package Typist::Definition;
use v5.40;

our $VERSION = '0.01';

use Scalar::Util 'blessed';

# Newtype, typeclass, and instance definitions.
# Extracted from Typist.pm for module decomposition.
# Functions that install symbols receive $caller explicitly.

sub _newtype ($caller, $name, $expr) {
    my $inner = Typist::Type->coerce($expr);
    my $type  = Typist::Type::Newtype->new($name, $inner);
    Typist::Registry->register_newtype($name, $type);

    my $class_name = "Typist::Newtype::$name";
    my $expr_str = $inner->to_string;
    no strict 'refs';
    *{"${caller}::${name}"} = sub ($value) {
        if ($Typist::RUNTIME) {
            die "Typist: $name — value does not satisfy $expr_str\n"
                unless $inner->contains($value);
        }
        bless \$value, $class_name;
    };

    *{"${name}::coerce"} = sub ($val) {
        die "Typist: ${name}::coerce — expected $name value\n"
            unless blessed($val) && blessed($val) eq $class_name;
        $$val;
    };
}

sub _typeclass ($caller, $name, $var_spec_arg, $methods_ref) {
    my $var_spec    = _coerce_var_spec($var_spec_arg);
    my %method_sigs = _coerce_method_sigs($methods_ref);

    my $def = Typist::TypeClass->new_class(
        name     => $name,
        var      => $var_spec,
        methods  => \%method_sigs,
        registry => 'Typist::Registry',
    );
    Typist::Registry->register_typeclass($name, $def);
    $def->install_dispatch($caller);
}

sub _coerce_var_spec ($arg) {
    return $arg unless ref $arg && $arg->isa('Typist::Type');
    my $spec = $arg->name;
    $spec .= ': ' . $arg->kind if $arg->can('kind') && $arg->kind;
    $spec;
}

sub _coerce_method_sigs ($methods_ref) {
    map {
        my $v = $methods_ref->{$_};
        $_ => (ref $v && $v->isa('Typist::Type') ? $v->to_string : $v)
    } keys %$methods_ref;
}

sub _instance ($class_name, $type_expr_arg, $methods_ref) {
    my $type_expr = ref $type_expr_arg && $type_expr_arg->isa('Typist::Type')
        ? $type_expr_arg->to_string
        : $type_expr_arg;
    my %methods = %$methods_ref;

    my $def = Typist::Registry->lookup_typeclass($class_name)
        // die "Typist: unknown typeclass '$class_name'\n";

    $def->check_instance_completeness($type_expr, %methods);
    $def->check_superclass_instances($type_expr, 'Typist::Registry');

    my $inst = Typist::TypeClass->new_instance(
        class     => $class_name,
        type_expr => $type_expr,
        methods   => \%methods,
    );
    Typist::Registry->register_instance($class_name, $type_expr, $inst);
}

1;
