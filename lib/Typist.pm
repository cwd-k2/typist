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
use Typist::TypeClass;
use Typist::Kind;
use Typist::KindChecker;
use Typist::Parser;
use Typist::Registry;
use Typist::Subtype;
use Typist::Inference;
use Typist::Attribute;
use Typist::Checker;
use Typist::Error;

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
}

# ── Newtype Support ─────────────────────────────

sub _newtype ($name, $expr) {
    my $inner = Typist::Parser->parse($expr);
    my $type  = Typist::Type::Newtype->new($name, $inner);
    Typist::Registry->register_newtype($name, $type);

    # Install a constructor function into the caller's namespace
    my $caller = caller;
    my $class_name = "Typist::Newtype::$name";
    no strict 'refs';
    *{"${caller}::${name}"} = sub ($value) {
        die "Typist: $name — value does not satisfy $expr\n"
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

    # Generate dispatch functions in a dedicated namespace
    my $ns = "Typist::TC::${name}";
    no strict 'refs';
    for my $method_name (keys %method_sigs) {
        *{"${ns}::${method_name}"} = sub {
            my @args = @_;
            # Infer type from first argument to resolve instance
            my $arg_type = Typist::Inference->infer_value($args[0]);
            my $inst = Typist::Registry->resolve_instance($name, $arg_type)
                // die "Typist: no instance of $name for " . $arg_type->to_string . "\n";
            my $impl = $inst->get_method($method_name)
                // die "Typist: instance $name for " . $inst->type_expr
                     . " missing method $method_name\n";
            $impl->(@args);
        };
        # Also install into caller's namespace for convenience
        *{"${caller}::${name}::${method_name}"} = \&{"${ns}::${method_name}"};
    }
}

sub _instance ($class_name, $type_expr, %methods) {
    my $def = Typist::Registry->lookup_typeclass($class_name)
        // die "Typist: unknown typeclass '$class_name'\n";

    # Check completeness: all required methods must be provided
    for my $required ($def->method_names) {
        die "Typist: instance $class_name for $type_expr missing method '$required'\n"
            unless exists $methods{$required};
    }

    my $inst = Typist::TypeClass->new_instance(
        class     => $class_name,
        type_expr => $type_expr,
        methods   => \%methods,
    );
    Typist::Registry->register_instance($class_name, $type_expr, $inst);
}

CHECK {
    Typist::Checker->new->analyze;
}

1;
