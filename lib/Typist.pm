package Typist;
use v5.40;

our $VERSION = '0.01';

use Typist::Type;
use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Struct;
use Typist::Type::Var;
use Typist::Type::Alias;
use Typist::Type::Literal;
use Typist::Type::Newtype;
use Typist::Type::Row;
use Typist::Type::Eff;
use Typist::Effect;
use Typist::TypeClass;
use Typist::Kind;
use Typist::KindChecker;
use Typist::Parser;
use Typist::Registry;
use Typist::Subtype;
use Typist::Inference;
use Typist::Attribute;
use Typist::Static::Checker;
use Typist::Error;
use Typist::Error::Global;
use Typist::DSL;

sub import ($class, @args) {
    my $caller = caller;

    # Track this package
    Typist::Registry->register_package($caller);

    # Install attribute handlers
    Typist::Attribute->install($caller);

    # Export typedef, newtype, unwrap into caller's namespace
    no strict 'refs';
    *{"${caller}::typedef"} = \&Typist::Registry::typedef;
    *{"${caller}::newtype"}   = \&_newtype;
    *{"${caller}::unwrap"}    = \&_unwrap;
    *{"${caller}::typeclass"} = \&_typeclass;
    *{"${caller}::instance"}  = \&_instance;
    *{"${caller}::effect"}    = \&_effect;
    *{"${caller}::declare"}   = \&_declare;
}

# ── Newtype Support ─────────────────────────────

sub _newtype ($name, $expr) {
    my $inner = Typist::Type->coerce($expr);
    my $type  = Typist::Type::Newtype->new($name, $inner);
    Typist::Registry->register_newtype($name, $type);

    # Install a constructor function into the caller's namespace
    my $caller = caller;
    my $class_name = "Typist::Newtype::$name";
    my $expr_str = $inner->to_string;
    no strict 'refs';
    *{"${caller}::${name}"} = sub ($value) {
        die "Typist: $name — value does not satisfy $expr_str\n"
            unless $inner->contains($value);
        bless \$value, $class_name;
    };
}

sub _unwrap ($value) {
    die "Typist: unwrap — not a newtype value\n"
        unless defined $value && ref $value && ref($value) =~ /\ATypist::Newtype::/;
    $$value;
}

# ── TypeClass Support ───────────────────────────

sub _typeclass ($name, $var_spec_arg, $methods_ref) {
    my $caller = caller;

    # Boundary coercion: DSL Type objects → strings for internal API
    my $var_spec    = _coerce_var_spec($var_spec_arg);
    my %method_sigs = _coerce_method_sigs($methods_ref);

    my $def = Typist::TypeClass->new_class(
        name    => $name,
        var     => $var_spec,
        methods => \%method_sigs,
    );
    Typist::Registry->register_typeclass($name, $def);
    $def->install_dispatch($caller);
}

# ── Boundary Coercion Helpers ──────────────────

sub _coerce_var_spec ($arg) {
    return $arg unless ref $arg && $arg->isa('Typist::Type');
    # Type::Var with optional kind → "T" or "F: * -> *"
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

# ── Effect Support ──────────────────────────────

sub _effect ($name, $operations_ref) {
    my $eff = Typist::Effect->new(
        name       => $name,
        operations => $operations_ref,
    );
    Typist::Registry->register_effect($name, $eff);
}

# ── Declare Support (external function annotations) ──

sub _declare ($name, $type_expr_str) {
    my $ann = Typist::Parser->parse_annotation($type_expr_str);
    my $type = $ann->{type};

    # Determine package and function name
    my ($pkg, $fn_name);
    if ($name =~ /::/) {
        ($pkg, $fn_name) = $name =~ /\A(.+)::(\w+)\z/;
        die("Typist: declare — invalid qualified name '$name'\n")
            unless $pkg && $fn_name;
    } else {
        ($pkg, $fn_name) = ('CORE', $name);
    }

    # Extract signature components
    my (@param_types, $return_type, $effects);
    if ($type->is_func) {
        @param_types = $type->params;
        $return_type = $type->returns;
        $effects     = $type->effects
            ? Typist::Type::Eff->new($type->effects) : undef;
    } else {
        $return_type = $type;
    }

    # Parse generic declarations
    my @generics;
    if ($ann->{generics_raw} && @{$ann->{generics_raw}}) {
        my $spec = join(', ', $ann->{generics_raw}->@*);
        @generics = Typist::Attribute->parse_generic_decl($spec);
    }

    Typist::Registry->register_function($pkg, $fn_name, +{
        params   => \@param_types,
        returns  => $return_type,
        generics => \@generics,
        effects  => $effects,
    });
}

sub _instance ($class_name, $type_expr_arg, $methods_ref) {
    # Boundary coercion: DSL Type object → string for internal API
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

CHECK {
    Typist::Error::Global->reset;
    Typist::Static::Checker->new->analyze;
    if (Typist::Error::Global->has_errors) {
        warn Typist::Error::Global->report;
    }
}

1;
