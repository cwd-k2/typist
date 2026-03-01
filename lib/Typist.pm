package Typist;
use v5.40;

use Scalar::Util 'blessed';

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
    *{"${caller}::handle"}    = \&_handle;
    *{"${caller}::match"}     = \&_match;
    *{"${caller}::enum"}      = \&_enum;
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
    my ($name, @type_params);
    if ($name_spec =~ /\A(\w+)\[(.+)\]\z/) {
        $name = $1;
        @type_params = map { s/\s//gr } split /,/, $2;
    } else {
        $name = $name_spec;
    }

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
