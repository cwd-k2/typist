package Typist;
use v5.40;

our $VERSION = '0.01';
our $RUNTIME     = $ENV{TYPIST_RUNTIME}     ? 1 : 0;
our $CHECK_QUIET = $ENV{TYPIST_CHECK_QUIET} ? 1 : 0;

my $NEWTYPE_RE = qr/\ATypist::Newtype::/;

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
use Typist::Type::Data;
use Typist::Effect;
use Typist::TypeClass;
use Typist::Kind;
use Typist::KindChecker;
use Typist::Parser;
use Typist::Registry;
use Typist::Subtype;
use Typist::Inference;
use Typist::Attribute;
use Typist::Handler;
use Typist::Static::Checker;
use Typist::Error;
use Typist::Error::Global;
use Typist::DSL;

sub import ($class, @args) {
    my $caller = caller;
    $Typist::RUNTIME = 1 if grep { $_ eq '-runtime' } @args;

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
    *{"${caller}::datatype"}  = \&_datatype;
    *{"${caller}::perform"}   = \&_perform;
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
        unless defined $value && ref $value && ref($value) =~ $NEWTYPE_RE;
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

# ── Perform Support (effect operation dispatch) ──

sub _perform ($effect_name, $op_name, @args) {
    my $handler = Typist::Handler->find_handler($effect_name);

    if ($handler && exists $handler->{$op_name}) {
        return $handler->{$op_name}->(@args);
    }

    die "No handler for effect ${effect_name}::${op_name}\n";
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

# ── Datatype Support (Tagged Union / ADT) ──────

sub _datatype ($name, %variants) {
    my $caller = caller;
    my %parsed_variants;

    for my $tag (keys %variants) {
        my $spec = $variants{$tag};
        my @types;
        if (defined $spec && $spec =~ /\S/) {
            my $inner = $spec;
            $inner =~ s/\A\(\s*//;
            $inner =~ s/\s*\)\z//;
            @types = map { Typist::Parser->parse($_) } split /\s*,\s*/, $inner;
        }
        $parsed_variants{$tag} = \@types;

        # Install constructor function into caller's namespace
        my @captured_types = @types;
        my $tag_copy  = $tag;
        my $data_class = "Typist::Data::${name}";
        no strict 'refs';
        *{"${caller}::${tag_copy}"} = sub (@args) {
            die("${tag_copy}(): expected "
                . scalar(@captured_types)
                . " arguments, got "
                . scalar(@args) . "\n")
                unless @args == @captured_types;
            for my $i (0 .. $#captured_types) {
                die("${tag_copy}(): argument "
                    . ($i + 1)
                    . " expected "
                    . $captured_types[$i]->to_string
                    . ", got $args[$i]\n")
                    unless $captured_types[$i]->contains($args[$i]);
            }
            bless +{ _tag => $tag_copy, _values => \@args }, $data_class;
        };
    }

    my $data_type = Typist::Type::Data->new($name, \%parsed_variants);
    Typist::Registry->register_datatype($name, $data_type);
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

    # 1. Structural checks on global Registry (alias cycles, free vars, bounds, kinds)
    Typist::Static::Checker->new->analyze;

    # 2. Full static analysis per loaded file (TypeChecker + EffectChecker)
    #    Skipped when CHECK_QUIET — typist-lsp provides the same diagnostics.
    _check_analyze() unless $CHECK_QUIET;

    if (Typist::Error::Global->has_errors && !$CHECK_QUIET) {
        warn Typist::Error::Global->report;
    }
}

# ── CHECK-Phase Static Analysis ──────────────────

sub _check_analyze () {
    require Typist::Static::Analyzer;

    my $ws_registry = Typist::Registry->_default;

    for my $pkg (Typist::Registry->all_packages) {
        my $file   = _package_to_file($pkg) // next;
        my $source = _slurp($file)          // next;

        my $result = eval {
            Typist::Static::Analyzer->analyze($source,
                workspace_registry => $ws_registry,
                file               => $file,
            );
        };
        next if $@;

        for my $diag ($result->{diagnostics}->@*) {
            Typist::Error::Global->collect(
                kind    => $diag->{kind},
                message => $diag->{message},
                file    => $diag->{file} // $file,
                line    => $diag->{line} // 0,
            );
        }
    }
}

sub _package_to_file ($pkg) {
    return $0 if $pkg eq 'main' && -f $0;
    my $path = $pkg =~ s|::|/|gr;
    $INC{"${path}.pm"};
}

sub _slurp ($path) {
    open my $fh, '<', $path or return undef;
    local $/;
    scalar readline $fh;
}

1;
