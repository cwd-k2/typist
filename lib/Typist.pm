package Typist;
use v5.40;

use Scalar::Util 'blessed';

our $VERSION = '0.01';
our $RUNTIME     = $ENV{TYPIST_RUNTIME}     ? 1 : 0;
our $CHECK_QUIET = $ENV{TYPIST_CHECK_QUIET} ? 1 : 0;

use Typist::Type;
use Typist::Type::Atom;
use Typist::Type::Param;
use Typist::Type::Union;
use Typist::Type::Intersection;
use Typist::Type::Func;
use Typist::Type::Record;
use Typist::Type::Var;
use Typist::Type::Alias;
use Typist::Type::Literal;
use Typist::Type::Newtype;
use Typist::Type::Row;
use Typist::Type::Eff;
use Typist::Type::Data;
use Typist::Type::Struct;
use Typist::Struct::Base;
use Typist::Newtype::Base;
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

    # Suppress "attribute may clash with future reserved word" for :sig
    my $prev_warn = $SIG{__WARN__};
    $SIG{__WARN__} = sub {
        return if $_[0] =~ /attribute may clash with future reserved word/;
        if ($prev_warn) { $prev_warn->(@_) }
        else            { warn $_[0] }
    };

    my @dsl_names;
    for my $arg (@args) {
        if    ($arg eq '-runtime') { $Typist::RUNTIME = 1 }
        elsif ($arg =~ /\A[A-Z]/ || $arg eq 'optional') { push @dsl_names, $arg }
    }

    # Track this package
    Typist::Registry->register_package($caller);

    # Install attribute handlers
    Typist::Attribute->install($caller);

    # Export core functions into caller's namespace
    no strict 'refs';
    *{"${caller}::typedef"} = \&Typist::Registry::typedef;
    *{"${caller}::newtype"}   = \&_newtype;
    *{"${caller}::typeclass"} = \&_typeclass;
    *{"${caller}::instance"}  = \&_instance;
    *{"${caller}::effect"}    = \&_effect;
    *{"${caller}::declare"}   = \&_declare;
    *{"${caller}::datatype"}  = \&_datatype;
    *{"${caller}::handle"}    = \&_handle;
    *{"${caller}::match"}     = \&_match;
    *{"${caller}::enum"}      = \&_enum;
    *{"${caller}::struct"}    = sub ($name, @fields) { _struct($name, $caller, @fields) };
    *{"${caller}::protocol"}  = \&_make_protocol;

    # Selective DSL re-export
    if (@dsl_names) {
        my $map = Typist::DSL->export_map;
        for my $name (@dsl_names) {
            die "Typist: unknown export '$name'\n" unless exists $map->{$name};
            *{"${caller}::${name}"} = $map->{$name};
        }
    }
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
    @{"${class_name}::ISA"} = ('Typist::Newtype::Base');
    *{"${caller}::${name}"} = sub ($value) {
        die "Typist: $name — value does not satisfy $expr_str\n"
            unless $inner->contains($value);
        bless \$value, $class_name;
    };
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

# ── Protocol Support ────────────────────────────

sub _make_protocol (@args) {
    if (@args == 1 && !ref $args[0]) {
        # protocol('From -> To') — single transition marker
        my ($from, $to) = $args[0] =~ /^\s*(\w+)\s*->\s*(\w+)\s*$/;
        die "Invalid protocol transition: '$args[0]'\n" unless defined $from;
        return +{ __protocol_transition__ => 1, from => $from, to => $to };
    }
    die "Invalid protocol() call\n";
}

# ── Effect Support ──────────────────────────────

sub _effect ($name, @rest) {
    my ($states, $operations_ref);
    if (ref $rest[0] eq 'ARRAY') {
        # New syntax: effect Name, [states] => +{...}
        $states = shift @rest;
        $operations_ref = shift @rest;
    } else {
        # Protocol-less: effect Name => +{...}
        $operations_ref = shift @rest;
    }

    # Process operation values: string or [sig, protocol('From -> To')]
    my (%ops, %transitions);
    for my $op_name (keys %$operations_ref) {
        my $val = $operations_ref->{$op_name};
        if (ref $val eq 'ARRAY') {
            $ops{$op_name} = $val->[0];
            if (ref $val->[1] eq 'HASH' && $val->[1]{__protocol_transition__}) {
                my $t = $val->[1];
                $transitions{$t->{from}}{$op_name} = $t->{to};
            }
        } else {
            $ops{$op_name} = $val;
        }
    }

    my $protocol;
    if (%transitions) {
        require Typist::Protocol;
        $protocol = Typist::Protocol->new(
            transitions => +{%transitions},
            ($states ? (states => $states) : ()),
        );
    }

    my $eff = Typist::Effect->new(
        name       => $name,
        operations => \%ops,
        protocol   => $protocol,
    );
    Typist::Registry->register_effect($name, $eff);

    # Install qualified subs for direct effect operation calls
    for my $op_name (keys %ops) {
        my ($eff_name, $op) = ($name, $op_name);
        no strict 'refs';
        *{"${eff_name}::${op}"} = sub (@args) {
            my $handler = Typist::Handler->find_handler($eff_name);
            if ($handler && exists $handler->{$op}) {
                return $handler->{$op}->(@args);
            }
            die "No handler for effect ${eff_name}::${op}\n";
        };
    }
}

# ── Handle Support (scoped effect handler block) ──
#
#   handle { BODY } Effect => +{ op => sub ... }, ...;
#
# The (&@) prototype allows bare-block syntax at call sites.
# Pushes handlers, executes BODY, pops handlers (even on exception),
# and returns BODY's result.

sub _handle :prototype(&@) {
    my ($body, @handler_specs) = @_;

    # Push all effect handlers onto the stack
    my $pushed = 0;
    while (@handler_specs >= 2) {
        my $effect   = shift @handler_specs;
        my $handlers = shift @handler_specs;
        Typist::Handler->push_handler($effect, $handlers);
        $pushed++;
    }

    # Execute body, ensuring handlers are popped even on exception
    my @result;
    my $ok = eval {
        @result = $body->();
        1;
    };
    my $err = $@;

    # Pop handlers (LIFO — matches push order)
    Typist::Handler->pop_handler for 1 .. $pushed;

    # Re-raise if body threw
    die $err unless $ok;

    wantarray ? @result : $result[0];
}

# ── Match Support (ADT pattern dispatch) ─────────
#
#   match $value,
#       Tag1 => sub ($a, $b) { ... },
#       Tag2 => sub ($x)     { ... },
#       _    => sub           { ... };   # optional fallback
#
# Dispatches on _tag, splats _values into the handler.

sub _match ($value, %arms) {
    my $tag = $value->{_tag}
        // die "Typist: match — value has no _tag\n";

    # Exhaustiveness: warn if known ADT has uncovered variants (no fallback _)
    if (!exists $arms{_} && blessed($value)) {
        my $class = blessed($value);
        if ($class =~ /\ATypist::Data::(\w+)\z/) {
            my $dt = Typist::Registry->lookup_datatype($1);
            if ($dt) {
                my @missing = grep { !exists $arms{$_} }
                    sort keys $dt->variants->%*;
                warn "Typist: match — non-exhaustive pattern: missing "
                    . join(', ', @missing) . "\n"
                    if @missing;
            }
        }
    }

    my $handler = $arms{$tag} // $arms{_}
        // die "Typist: match — no arm for tag '$tag' and no fallback '_'\n";

    $handler->($value->{_values} ? $value->{_values}->@* : ());
}

# ── Enum Support (nullary ADT sugar) ─────────────
#
#   enum Color => qw(Red Green Blue);
#
# Syntactic sugar for datatype with all-nullary variants.
# Each variant is a zero-argument constructor.

sub _enum ($name, @tags) {
    my $caller = caller;
    my %variants;
    for my $tag (@tags) {
        $variants{$tag} = '';
    }
    # Delegate to _datatype, but need to set caller correctly.
    # Instead, inline the registration and constructor installation.
    my %parsed_variants;
    my $data_class = "Typist::Data::${name}";
    for my $tag (@tags) {
        $parsed_variants{$tag} = [];
        my $tag_copy = $tag;
        no strict 'refs';
        *{"${caller}::${tag_copy}"} = sub () {
            bless +{ _tag => $tag_copy, _values => [] }, $data_class;
        };
    }
    my $data_type = Typist::Type::Data->new($name, \%parsed_variants);
    Typist::Registry->register_datatype($name, $data_type);

    # Register constructor functions for CHECK-phase cross-file inference.
    for my $tag (@tags) {
        Typist::Registry->register_function($caller, $tag, +{
            params      => [],
            returns     => $data_type,
            generics    => [],
            constructor => 1,
        });
    }
}

# ── Struct Support (nominal blessed immutable structs) ──

sub _struct ($name_spec, $caller, @field_pairs) {
    die "Typist: struct '$name_spec' — odd number of field arguments\n"
        if @field_pairs % 2;

    # Parse name and type parameters: 'Pair[T, U]', 'NumBox[T: Num]', or plain 'Point'
    my ($name, @type_params, @raw_specs);
    ($name, @raw_specs) = Typist::Parser->parse_parameterized_name($name_spec);
    @type_params = map { /\A(\w+)/ ? $1 : $_ } @raw_specs;

    # Parse bounds and typeclass constraints from raw specs
    my (%bounds, %tc);
    if (@raw_specs) {
        my @generics = Typist::Attribute->parse_generic_decl(
            join(', ', @raw_specs), registry => 'Typist::Registry',
        );
        for my $g (@generics) {
            if ($g->{bound_expr}) {
                $bounds{$g->{name}} = Typist::Parser->parse($g->{bound_expr});
            }
            if ($g->{tc_constraints}) {
                $tc{$g->{name}} = $g->{tc_constraints};
            }
        }
    }

    my %var_names = map { $_ => 1 } @type_params;
    my %field_spec = @field_pairs;
    my (%required_types, %optional_types);

    for my $key (keys %field_spec) {
        my $val = $field_spec{$key};
        if (blessed($val) && $val->isa('Typist::DSL::Optional')) {
            $optional_types{$key} = $val->inner;
        } else {
            my $type = Typist::Type->coerce($val);
            $required_types{$key} = $type;
        }
    }

    my $record = Typist::Type::Record->from_parts(
        required => \%required_types,
        optional => \%optional_types,
    );

    my $pkg = "Typist::Struct::${name}";
    my %type_bounds;
    for my $param (keys %bounds) {
        $type_bounds{$param} = $bounds{$param}->to_string;
    }
    for my $param (keys %tc) {
        $type_bounds{$param} //= join(' + ', $tc{$param}->@*);
    }
    my $type = Typist::Type::Struct->new(
        name        => $name,
        record      => $record,
        package     => $pkg,
        type_params => \@type_params,
        type_bounds => \%type_bounds,
    );

    # 1. Register in Registry
    Typist::Registry->register_type($name, $type);

    # 2. Generate the package (ISA, meta, accessors)
    {
        no strict 'refs';
        @{"${pkg}::ISA"} = ('Typist::Struct::Base');

        my %all_types = (%required_types, %optional_types);
        my %req_copy  = %required_types;
        my %opt_copy  = %optional_types;
        my $meta = +{
            name     => $name,
            required => \%req_copy,
            optional => \%opt_copy,
        };
        *{"${pkg}::_typist_struct_meta"} = sub { $meta };

        # Accessors for each field
        for my $field (keys %all_types) {
            my $f = $field;  # capture
            *{"${pkg}::${f}"} = sub ($self) { $self->{$f} };
        }
    }

    # 3. Install constructor in caller's namespace
    {
        my %req = %required_types;
        my %opt = %optional_types;
        my %all = (%req, %opt);
        my @tp  = @type_params;
        no strict 'refs';
        *{"${caller}::${name}"} = sub (@args) {
            die "Typist: ${name}() — odd number of arguments\n"
                if @args % 2;
            my %given = @args;

            # Check for unknown fields
            for my $k (keys %given) {
                die "Typist: ${name}() — unknown field '$k'\n"
                    unless exists $all{$k};
            }

            # Check required fields
            for my $k (keys %req) {
                die "Typist: ${name}() — missing required field '$k'\n"
                    unless exists $given{$k};
            }

            if (@tp) {
                # Parameterized: infer type args from field values, then validate
                my %bindings;
                for my $k (keys %given) {
                    my $formal = $all{$k};
                    next unless $formal->is_var && $var_names{$formal->name};
                    my $inferred = Typist::Inference->infer_value($given{$k});
                    if (exists $bindings{$formal->name}) {
                        $bindings{$formal->name} = Typist::Subtype->common_super(
                            $bindings{$formal->name}, $inferred,
                        );
                    } else {
                        $bindings{$formal->name} = $inferred;
                    }
                }
                # Bounded quantification check
                for my $param (keys %bounds) {
                    my $actual = $bindings{$param} // next;
                    unless (Typist::Subtype->is_subtype($actual, $bounds{$param})) {
                        die "Typist: ${name}() — type ${\$actual->to_string} does not satisfy bound ${\$bounds{$param}->to_string} for $param\n";
                    }
                }
                # Typeclass constraint check
                for my $param (keys %tc) {
                    my $actual = $bindings{$param} // next;
                    for my $tc_name ($tc{$param}->@*) {
                        unless (Typist::Registry->resolve_instance($tc_name, $actual)) {
                            die "Typist: ${name}() — no instance of $tc_name for ${\$actual->to_string}\n";
                        }
                    }
                }

                for my $k (keys %given) {
                    my $exp = %bindings
                        ? $all{$k}->substitute(\%bindings)
                        : $all{$k};
                    unless ($exp->contains($given{$k})) {
                        die "Typist: ${name}() — field '$k' expected "
                            . $exp->to_string . ", got $given{$k}\n";
                    }
                }

                my @type_args = map {
                    $bindings{$_} // Typist::Type::Atom->new('Any')
                } @tp;

                bless +{%given, _type_args => \@type_args}, $pkg;
            } else {
                # Non-parameterized: validate directly
                for my $k (keys %given) {
                    my $expected = $all{$k};
                    unless ($expected->contains($given{$k})) {
                        die "Typist: ${name}() — field '$k' expected "
                            . $expected->to_string . ", got $given{$k}\n";
                    }
                }

                bless +{%given}, $pkg;
            }
        };
    }

    # 4. Register constructor function so CHECK-phase cross-file inference
    #    can resolve calls like OrderItem(...) from other packages.
    my @generics = @raw_specs
        ? Typist::Attribute->parse_generic_decl(join(', ', @raw_specs), registry => 'Typist::Registry')
        : map { +{ name => $_, bound_expr => undef } } @type_params;
    Typist::Registry->register_function($caller, $name, +{
        params             => [],
        returns            => $type,
        generics           => \@generics,
        struct_constructor => 1,
    });
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

sub _datatype ($name_spec, %variants) {
    my $caller = caller;

    # Parse name and type parameters: 'Name[T, U]' or plain 'Name'
    my ($name, @raw);
    ($name, @raw) = Typist::Parser->parse_parameterized_name($name_spec);
    my @type_params = map { s/\s//gr } @raw;

    my %var_names = map { $_ => 1 } @type_params;
    my (%parsed_variants, %return_types);

    for my $tag (keys %variants) {
        my ($types, $ret_expr) = Typist::Type::Data->parse_constructor_spec(
            $variants{$tag}, type_params => \@type_params,
        );
        $parsed_variants{$tag} = $types;

        # GADT: parse and record per-constructor return type
        my $forced_args;  # arrayref of forced type args for GADT, undef for normal
        if (defined $ret_expr) {
            my $ret_type = Typist::Parser->parse($ret_expr);
            $return_types{$tag} = $ret_type;
            # Extract forced type arguments from return type (e.g., Expr[Int] → [Int])
            if ($ret_type->is_param) {
                $forced_args = [$ret_type->params];
            }
        }

        # Install constructor function into caller's namespace
        my @captured_types = @$types;
        my $tag_copy   = $tag;
        my $data_class = "Typist::Data::${name}";
        my @tp = @type_params;
        my $fa = $forced_args;
        no strict 'refs';
        *{"${caller}::${tag_copy}"} = sub (@args) {
            die("${tag_copy}(): expected "
                . scalar(@captured_types)
                . " arguments, got "
                . scalar(@args) . "\n")
                unless @args == @captured_types;

            if (@tp) {
                # Parameterized: infer type args, then validate
                my %bindings;
                for my $i (0 .. $#captured_types) {
                    my $formal = $captured_types[$i];
                    next unless $formal->is_var && $var_names{$formal->name};
                    my $inferred = Typist::Inference->infer_value($args[$i]);
                    if (exists $bindings{$formal->name}) {
                        $bindings{$formal->name} = Typist::Subtype->common_super(
                            $bindings{$formal->name}, $inferred,
                        );
                    } else {
                        $bindings{$formal->name} = $inferred;
                    }
                }
                for my $i (0 .. $#captured_types) {
                    my $exp = %bindings
                        ? $captured_types[$i]->substitute(\%bindings)
                        : $captured_types[$i];
                    unless ($exp->contains($args[$i])) {
                        die("${tag_copy}(): argument "
                            . ($i + 1) . " expected "
                            . $exp->to_string . ", got $args[$i]\n");
                    }
                }

                # GADT: forced type args override inferred ones
                my @type_args;
                if ($fa) {
                    for my $i (0 .. $#tp) {
                        my $f = $fa->[$i];
                        if ($f && !$f->is_var) {
                            push @type_args, $f;  # forced by GADT constraint
                        } else {
                            push @type_args,
                                $bindings{$tp[$i]} // Typist::Type::Atom->new('Any');
                        }
                    }
                } else {
                    @type_args = map {
                        $bindings{$_} // Typist::Type::Atom->new('Any')
                    } @tp;
                }

                bless +{
                    _tag       => $tag_copy,
                    _values    => \@args,
                    _type_args => \@type_args,
                }, $data_class;
            } else {
                # Non-parameterized: validate directly
                for my $i (0 .. $#captured_types) {
                    unless ($captured_types[$i]->contains($args[$i])) {
                        die("${tag_copy}(): argument "
                            . ($i + 1) . " expected "
                            . $captured_types[$i]->to_string
                            . ", got $args[$i]\n");
                    }
                }
                bless +{ _tag => $tag_copy, _values => \@args }, $data_class;
            }
        };
    }

    my $data_type = Typist::Type::Data->new($name, \%parsed_variants,
        type_params  => \@type_params,
        return_types => (%return_types ? \%return_types : +{}),
    );
    Typist::Registry->register_datatype($name, $data_type);

    # Register constructor functions so CHECK-phase cross-file inference
    # can resolve calls like Ok(1), Some(v), None() from other packages.
    for my $tag (keys %parsed_variants) {
        my $param_types = $parsed_variants{$tag};
        my $return_type;
        if (exists $return_types{$tag}) {
            $return_type = $return_types{$tag};
        } elsif (@type_params) {
            my @vars = map { Typist::Type::Var->new($_) } @type_params;
            $return_type = Typist::Type::Param->new($name, @vars);
        } else {
            $return_type = $data_type;
        }
        my @generics = map { +{ name => $_, bound_expr => undef } } @type_params;
        Typist::Registry->register_function($caller, $tag, +{
            params    => $param_types,
            returns   => $return_type,
            generics  => \@generics,
            constructor => 1,
        });
    }
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

    # 0. Ensure Prelude effects (IO/Exn/Decl) + CORE builtins are in the default
    #    Registry so CHECK-phase analysis can resolve them.  Idempotent.
    require Typist::Prelude;
    Typist::Prelude->install(Typist::Registry->_default);

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

__END__

=head1 NAME

Typist - A static-first type system for Perl 5

=head1 SYNOPSIS

    use Typist;
    use Typist::DSL;

    # Type aliases
    BEGIN {
        typedef Name => Str;
    }

    # Typed variables
    my $count :sig(Int) = 0;

    # Typed subroutines
    sub add :sig((Int, Int) -> Int) ($a, $b) {
        $a + $b;
    }

    # Generics with bounded quantification
    sub max_of :sig(<T: Num>(T, T) -> T) ($a, $b) {
        $a > $b ? $a : $b;
    }

=head1 DESCRIPTION

Typist brings static type annotations to Perl through the standard attribute
syntax C<:sig(...)>. Errors are caught at compile time (CHECK phase) and
via the LSP server, with zero runtime overhead by default.

    use Typist;            # Static-only (default)
    use Typist -runtime;   # Enable runtime enforcement

=head1 EXPORTS

The following are exported into the caller's namespace:

=head2 typedef

    typedef Name => Str;

Define a type alias. The right-hand side is a type expression string
or a L<Typist::Type> object.

=head2 newtype

    newtype UserId => 'Int';

Define a nominal type with boundary enforcement. Constructor validates
values at creation time. Use C<< $val->base >> (L<Typist::Newtype::Base>)
to extract the inner value.

=head2 struct

    struct Person => (name => 'Str', age => 'Int');

Define a nominal struct type with a constructor, field accessors,
and immutable update via C<< $obj->with(field => val) >>.
Use C<optional(Type)> for optional fields.

=head2 datatype

    datatype Shape => Circle => '(Int)', Rectangle => '(Int, Int)';

Define an algebraic data type (tagged union) with constructors
installed into the caller's namespace.

=head2 enum

    enum Color => qw(Red Green Blue);

Define a nullary-only ADT (pure enumeration).
Sugar for C<datatype> with all zero-argument variants.

=head2 match

    match $value, Tag => sub (...) { ... }, _ => sub { ... };

Pattern match on an ADT value. Dispatches on C<_tag> and splats C<_values>
into handlers. C<_> is the optional fallback arm.

=head2 handle

    handle { BODY } Effect => +{ op => sub { ... } };

Install scoped effect handlers, execute BODY, and guarantee cleanup.
No comma after the block (same rule as C<map>/C<grep>).

=head2 typeclass

    typeclass Show => T, +{ show => '(T) -> Str' };

Define a type class with method signatures. Methods are installed as
qualified dispatch subs into the caller's namespace.

=head2 instance

    instance Show => Int, +{ show => sub ($x) { "$x" } };

Provide a type class instance. Validates method completeness
against the class definition and checks superclass instances.

=head2 effect

    effect Console => +{ log => '(Str) -> Void' };

Define an algebraic effect with named operations. Operations are
auto-installed as qualified subs (e.g. C<< Console::log(@args) >>).

With protocol (stateful effects):

    effect 'DB', [qw(None Connected Authed)] => +{
        connect => ['(Str) -> Void', protocol('None -> Connected')],
        query   => ['(Str) -> Str',  protocol('Authed -> Authed')],
    };

=head2 protocol

    protocol('From -> To')

Inline state transition marker for effect protocols.
Used inside C<effect> definitions to attach FSM transitions to operations.

=head2 declare

    declare say => '(Str) -> Void ![Console]';

Annotate an external function's type signature. Overrides
L<Typist::Prelude> entries for the declared name.

=head1 ENVIRONMENT

=over 4

=item C<TYPIST_RUNTIME>

Set to C<1> to enable runtime type enforcement.

=item C<TYPIST_CHECK_QUIET>

Set to C<1> to suppress CHECK-phase diagnostics (use when the LSP server
provides diagnostics).

=back

=head1 SEE ALSO

L<Typist::DSL> for type constructors and DSL syntax.

See F<docs/type-system.md> and F<docs/architecture.md> for detailed reference.

=head1 LICENSE

MIT License.

=cut
