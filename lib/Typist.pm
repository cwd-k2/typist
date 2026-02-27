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

sub _typeclass ($name, $var_spec, %method_sigs) {
    my $caller = caller;

    my $def = Typist::TypeClass->new_class(
        name    => $name,
        var     => $var_spec,
        methods => \%method_sigs,
    );
    Typist::Registry->register_typeclass($name, $def);
    $def->install_dispatch($caller);
}

# ── Effect Support ──────────────────────────────

sub _effect ($name, $operations_ref) {
    my $eff = Typist::Effect->new(
        name       => $name,
        operations => $operations_ref,
    );
    Typist::Registry->register_effect($name, $eff);
}

sub _instance ($class_name, $type_expr, %methods) {
    my $def = Typist::Registry->lookup_typeclass($class_name)
        // die "Typist: unknown typeclass '$class_name'\n";

    $def->check_instance_completeness($type_expr, %methods);

    my $inst = Typist::TypeClass->new_instance(
        class     => $class_name,
        type_expr => $type_expr,
        methods   => \%methods,
    );
    Typist::Registry->register_instance($class_name, $type_expr, $inst);
}

CHECK {
    Typist::Static::Checker->new->analyze;
}

1;
