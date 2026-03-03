package Typist::Static::Registration;
use v5.40;

our $VERSION = '0.01';

use Typist::Parser;
use Typist::Type::Newtype;
use Typist::Type::Data;
use Typist::Type::Eff;
use Typist::Type::Row;
use Typist::Type::Var;
use Typist::Type::Param;
use Typist::Effect;
use Typist::TypeClass;
use Typist::Attribute;
use Typist::Transform;
use Typist::Type::Record;
use Typist::Type::Struct;

# ── Public API ───────────────────────────────────
#
# All register_* methods accept:
#   $extracted — hashref from Extractor
#   $registry  — Typist::Registry instance
#   %opts      — errors => Collector, file => filename (both optional)
#
# When errors/file are absent, parse failures are silently skipped.

sub register_all ($class, $extracted, $registry, %opts) {
    $class->register_aliases($extracted, $registry, %opts);
    $class->register_newtypes($extracted, $registry, %opts);
    $class->register_typeclasses($extracted, $registry, %opts);
    $class->register_instances($extracted, $registry, %opts);
    $class->register_structs($extracted, $registry, %opts);
    $class->register_datatypes($extracted, $registry, %opts);
    $class->register_effects($extracted, $registry, %opts);
    $class->register_declares($extracted, $registry, %opts);
    $class->register_functions($extracted, $registry, %opts);
}

# ── Aliases ──────────────────────────────────────

sub register_aliases ($class, $extracted, $registry, %opts) {
    my ($errors, $file) = @opts{qw(errors file)};

    for my $name (sort keys $extracted->{aliases}->%*) {
        my $info = $extracted->{aliases}{$name};
        my $parsed = eval { Typist::Parser->parse($info->{expr}) };
        if ($@ && $errors) {
            $errors->collect(
                kind    => 'ResolveError',
                message => "Failed to parse typedef '$name': $@",
                file    => $file // '(buffer)',
                line    => $info->{line},
            );
            next;
        }
        next unless $parsed;
        $registry->define_alias($name, $info->{expr});
    }
}

# ── Newtypes ─────────────────────────────────────

sub register_newtypes ($class, $extracted, $registry, %opts) {
    my ($errors, $file) = @opts{qw(errors file)};
    my $pkg = $extracted->{package} // 'main';

    for my $name (sort keys $extracted->{newtypes}->%*) {
        my $info  = $extracted->{newtypes}{$name};
        my $inner = eval { Typist::Parser->parse($info->{inner_expr}) };
        if ($@ && $errors) {
            $errors->collect(
                kind    => 'ResolveError',
                message => "Failed to parse newtype '$name': $@",
                file    => $file // '(buffer)',
                line    => $info->{line},
            );
            next;
        }
        next unless $inner;

        my $type = Typist::Type::Newtype->new($name, $inner);
        $registry->register_newtype($name, $type);

        # Constructor: Name(Inner) -> Name
        $registry->register_function($pkg, $name, +{
            params       => [$inner],
            returns      => $type,
            generics     => [],
            params_expr  => [$inner->to_string],
            returns_expr => $name,
        });
    }
}

# ── Structs ─────────────────────────────────────

sub register_structs ($class, $extracted, $registry, %opts) {
    my ($errors, $file) = @opts{qw(errors file)};
    my $pkg = $extracted->{package} // 'main';

    for my $name (sort keys(($extracted->{structs} // +{})->%*)) {
        my $info = $extracted->{structs}{$name};
        my $fields = $info->{fields} // +{};
        my @opt_names = ($info->{optional_fields} // [])->@*;
        my %opt_set = map { $_ => 1 } @opt_names;
        my @tp = ($info->{type_params} // [])->@*;
        my %vn = map { $_ => 1 } @tp;

        # Parse field types (with Alias→Var conversion for type params)
        my (%required, %optional);
        for my $fname (keys %$fields) {
            my $type_str = $fields->{$fname};
            my $parsed = eval { Typist::Parser->parse($type_str) };
            if ($@ && $errors) {
                $errors->collect(
                    kind    => 'ResolveError',
                    message => "Failed to parse struct field type '$type_str' in $name.$fname: $@",
                    file    => $file // '(buffer)',
                    line    => $info->{line},
                );
                next;
            }
            next unless $parsed;
            $parsed = Typist::Transform->aliases_to_vars($parsed, \%vn) if @tp;

            if ($opt_set{$fname}) {
                $optional{$fname} = $parsed;
            } else {
                $required{$fname} = $parsed;
            }
        }

        my $record = Typist::Type::Record->from_parts(
            required => \%required,
            optional => \%optional,
        );
        my $struct_pkg = "Typist::Struct::${name}";
        # Parse generics with bound/typeclass support
        my @tp_specs = ($info->{type_param_specs} // [])->@*;
        my @generics;
        if (@tp_specs) {
            my $spec_str = join(', ', @tp_specs);
            @generics = Typist::Attribute->parse_generic_decl($spec_str, registry => $registry);
        } else {
            @generics = map { +{ name => $_, bound_expr => undef } } @tp;
        }

        my %type_bounds;
        for my $g (@generics) {
            next unless $g->{bound_expr} || $g->{tc_constraints};
            $type_bounds{$g->{name}} = $g->{bound_expr}
                // join(' + ', $g->{tc_constraints}->@*);
        }

        my $struct_type = Typist::Type::Struct->new(
            name        => $name,
            record      => $record,
            package     => $struct_pkg,
            type_params => \@tp,
            type_bounds => \%type_bounds,
        );
        $registry->register_type($name, $struct_type);

        # Constructor: variadic to accept named args, returns struct type
        my @ctor_params_expr;
        for my $fname (sort keys %required) {
            push @ctor_params_expr, "$fname: " . $required{$fname}->to_string;
        }
        for my $fname (sort keys %optional) {
            push @ctor_params_expr, "$fname?: " . $optional{$fname}->to_string;
        }
        $registry->register_function($pkg, $name, +{
            params       => [],
            returns      => $struct_type,
            generics     => \@generics,
            variadic     => 1,
            params_expr        => \@ctor_params_expr,
            returns_expr       => $name,
            constructor        => 1,
            struct_constructor => 1,
        });

        # Accessor methods on the struct package
        for my $fname (keys %required) {
            $registry->register_method($struct_pkg, $fname, +{
                params  => [],
                returns => $required{$fname},
            });
        }
        for my $fname (keys %optional) {
            $registry->register_method($struct_pkg, $fname, +{
                params  => [],
                returns => Typist::Type::Union->new(
                    $optional{$fname}, Typist::Type::Atom->new('Undef'),
                ),
            });
        }

        # with() method: returns the same struct type
        $registry->register_method($struct_pkg, 'with', +{
            params   => [],
            returns  => $struct_type,
            variadic => 1,
        });
    }
}

# ── Datatypes ────────────────────────────────────

sub register_datatypes ($class, $extracted, $registry, %opts) {
    my $pkg = $extracted->{package} // 'main';

    for my $name (sort keys(($extracted->{datatypes} // +{})->%*)) {
        my $info = $extracted->{datatypes}{$name};
        my @tp   = ($info->{type_params} // [])->@*;
        my (%parsed_variants, %return_types);

        for my $tag (keys $info->{variants}->%*) {
            my ($types, $ret_expr) = Typist::Type::Data->parse_constructor_spec(
                $info->{variants}{$tag}, type_params => \@tp,
            );
            $parsed_variants{$tag} = $types;

            if (defined $ret_expr) {
                my $ret_type = eval { Typist::Parser->parse($ret_expr) };
                $return_types{$tag} = $ret_type if $ret_type;
            }
        }

        my $dt = Typist::Type::Data->new($name, \%parsed_variants,
            type_params  => \@tp,
            return_types => (%return_types ? \%return_types : +{}),
        );
        $registry->register_datatype($name, $dt);

        # Constructors
        for my $tag (keys %parsed_variants) {
            my $param_types = $parsed_variants{$tag};
            my $return_type;

            if (exists $return_types{$tag}) {
                $return_type = $return_types{$tag};
            } elsif (@tp) {
                my @vars = map { Typist::Type::Var->new($_) } @tp;
                $return_type = Typist::Type::Param->new($name, @vars);
            } else {
                $return_type = $dt;
            }
            my @generics = map { +{ name => $_, bound_expr => undef } } @tp;
            $registry->register_function($pkg, $tag, +{
                params       => $param_types,
                returns      => $return_type,
                generics     => \@generics,
                params_expr  => [map { $_->to_string } @$param_types],
                returns_expr => $return_type->to_string,
                constructor  => 1,
            });
        }
    }
}

# ── Effects ──────────────────────────────────────

sub register_effects ($class, $extracted, $registry, %opts) {
    for my $name (sort keys $extracted->{effects}->%*) {
        my $eff_info = $extracted->{effects}{$name};
        my $ops = $eff_info->{operations} // +{};

        # Build Protocol object if extracted
        my $protocol;
        if (my $pd = $eff_info->{protocol}) {
            require Typist::Protocol;
            $protocol = Typist::Protocol->new(
                transitions => $pd,
                ($eff_info->{states} ? (states => $eff_info->{states}) : ()),
            );
        }

        $registry->register_effect($name,
            Typist::Effect->new(name => $name, operations => $ops, protocol => $protocol),
        );

        # Build per-op protocol transitions for ProtocolChecker
        my %op_transitions;
        if ($protocol) {
            for my $state ($protocol->states) {
                for my $op ($protocol->ops_in($state)) {
                    push $op_transitions{$op}->@*, +{
                        from => $state,
                        to   => $protocol->next_state($state, $op),
                    };
                }
            }
        }

        # Register effect operations as functions
        for my $op_name (sort keys %$ops) {
            my $sig_str = $ops->{$op_name};
            my $ann = eval { Typist::Parser->parse_annotation($sig_str) };
            next unless $ann;
            my $type = $ann->{type};
            my (@params, $returns);
            if ($type->is_func) {
                @params  = $type->params;
                $returns = $type->returns;
            } else {
                $returns = $type;
            }

            my %label_states;
            if (my $trans = $op_transitions{$op_name}) {
                $label_states{$name} = $trans->[0] if @$trans == 1;
            }
            my $eff_row = Typist::Type::Row->new(
                labels       => [$name],
                label_states => \%label_states,
            );
            my $effects = Typist::Type::Eff->new($eff_row);

            my $sig = +{
                params       => \@params,
                returns      => $returns,
                generics     => [],
                effects      => $effects,
                params_expr  => [map { $_->to_string } @params],
                returns_expr => $returns->to_string,
            };
            $sig->{protocol_transitions} = $op_transitions{$op_name}
                if $op_transitions{$op_name};

            $registry->register_function($name, $op_name, $sig);
        }
    }
}

# ── Typeclasses ──────────────────────────────────

sub register_typeclasses ($class, $extracted, $registry, %opts) {
    for my $name (sort keys $extracted->{typeclasses}->%*) {
        next if $registry->has_typeclass($name);
        my $info = $extracted->{typeclasses}{$name};
        my $def = eval {
            Typist::TypeClass->new_class(
                name    => $name,
                var     => $info->{var_spec} // 'T',
                methods => $info->{methods}  // +{},
            );
        };
        $registry->register_typeclass($name, $def // undef);
    }

    # Register typeclass methods as functions
    for my $tc_name (sort keys $extracted->{typeclasses}->%*) {
        my $tc_info = $extracted->{typeclasses}{$tc_name};
        my $methods = $tc_info->{methods} // +{};

        # Collect type variable names from var_spec (e.g. "T", "F: * -> *")
        my %tc_var_names;
        if (my $vs = $tc_info->{var_spec}) {
            my ($vname) = $vs =~ /\A(\w+)/;
            $tc_var_names{$vname} = 1 if $vname;
        }

        for my $method_name (sort keys %$methods) {
            my $sig_str = $methods->{$method_name};
            my $ann = eval { Typist::Parser->parse_annotation($sig_str) };
            next unless $ann;
            my $type = $ann->{type};

            # Merge var names from typeclass var_spec + annotation generics
            my %var_names = %tc_var_names;
            for my $g ($ann->{generics_raw}->@*) {
                my ($gname) = $g =~ /\A(\w+)/;
                $var_names{$gname} = 1 if $gname;
            }

            # Convert Alias nodes matching var names to Var nodes
            if (%var_names) {
                require Typist::Transform;
                $type = Typist::Transform->aliases_to_vars($type, \%var_names);
            }

            my (@params, $returns);
            if ($type->is_func) {
                @params  = $type->params;
                $returns = $type->returns;
            } else {
                $returns = $type;
            }

            my %seen;
            $seen{$_} = 1 for map { $_->free_vars } @params;
            if ($returns) { $seen{$_} = 1 for $returns->free_vars }
            my @generics = map { +{ name => $_, bound_expr => undef } } sort keys %seen;

            $registry->register_function($tc_name, $method_name, +{
                params       => \@params,
                returns      => $returns,
                generics     => \@generics,
                params_expr  => [map { $_->to_string } @params],
                returns_expr => $returns->to_string,
            });
        }
    }
}

# ── Instances ────────────────────────────────────

sub register_instances ($class, $extracted, $registry, %opts) {
    for my $info (($extracted->{instances} // [])->@*) {
        my $inst = Typist::TypeClass->new_instance(
            class     => $info->{class_name},
            type_expr => $info->{type_expr},
            methods   => +{},
        );
        $registry->register_instance($info->{class_name}, $info->{type_expr}, $inst);
    }
}

# ── Declares ─────────────────────────────────────

sub register_declares ($class, $extracted, $registry, %opts) {
    my ($errors, $file) = @opts{qw(errors file)};

    for my $name (sort keys $extracted->{declares}->%*) {
        my $decl = $extracted->{declares}{$name};
        my $ann = eval { Typist::Parser->parse_annotation($decl->{type_expr}) };
        if ($@ && $errors) {
            $errors->collect(
                kind    => 'ResolveError',
                message => "Failed to parse declare type for '$name': $@",
                file    => $file // '(buffer)',
                line    => $decl->{line},
            );
            next;
        }
        next unless $ann;

        my $type = $ann->{type};
        my (@param_types, $return_type, $effects);

        if ($type->is_func) {
            @param_types = $type->params;
            $return_type = $type->returns;
            $effects = $type->effects
                ? Typist::Type::Eff->new($type->effects) : undef;
        } else {
            $return_type = $type;
        }

        my @generics;
        if ($ann->{generics_raw} && @{$ann->{generics_raw}}) {
            my $spec = join(', ', $ann->{generics_raw}->@*);
            @generics = Typist::Attribute->parse_generic_decl($spec, registry => $registry);
        }

        $registry->register_function($decl->{package}, $decl->{func_name}, +{
            params       => \@param_types,
            returns      => $return_type,
            generics     => \@generics,
            effects      => $effects,
            params_expr  => [map { $_->to_string } @param_types],
            returns_expr => $return_type ? $return_type->to_string : undef,
            declared     => 1,
        });
    }
}

# ── Functions ────────────────────────────────────

sub register_functions ($class, $extracted, $registry, %opts) {
    my ($errors, $file) = @opts{qw(errors file)};
    my $pkg = $extracted->{package} // 'main';

    for my $name (sort keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};

        my @param_types;
        for my $expr ($fn->{params_expr}->@*) {
            my $t = eval { Typist::Parser->parse($expr) };
            if ($@ && $errors) {
                $errors->collect(
                    kind    => 'ResolveError',
                    message => "Failed to parse param type '$expr' in $name: $@",
                    file    => $file // '(buffer)',
                    line    => $fn->{line},
                );
                next;
            }
            next unless $t;
            push @param_types, $t;
        }

        my $return_type;
        if ($fn->{returns_expr}) {
            $return_type = eval { Typist::Parser->parse($fn->{returns_expr}) };
            if ($@ && $errors) {
                $errors->collect(
                    kind    => 'ResolveError',
                    message => "Failed to parse return type '$fn->{returns_expr}' in $name: $@",
                    file    => $file // '(buffer)',
                    line    => $fn->{line},
                );
            }
        }

        my $effects;
        if ($fn->{unannotated}) {
            $effects = Typist::Type::Eff->new(
                Typist::Type::Row->new(labels => [], row_var => '*'),
            );
        }
        elsif ($fn->{eff_expr}) {
            $effects = eval {
                my $row = Typist::Parser->parse_row($fn->{eff_expr});
                Typist::Type::Eff->new($row);
            };
            if ($@ && $errors) {
                $errors->collect(
                    kind    => 'ResolveError',
                    message => "Failed to parse effect annotation '$fn->{eff_expr}' in $name: $@",
                    file    => $file // '(buffer)',
                    line    => $fn->{line},
                );
            }
        }

        my @generics;
        if ($fn->{generics} && @{$fn->{generics}}) {
            my $spec = join(', ', $fn->{generics}->@*);
            @generics = Typist::Attribute->parse_generic_decl($spec, registry => $registry);
        }

        my $sig = +{
            params        => \@param_types,
            returns       => $return_type,
            generics      => \@generics,
            effects       => $effects,
            default_count => $fn->{default_count} // 0,
            params_expr   => $fn->{params_expr},
            returns_expr  => $fn->{returns_expr},
            ($fn->{variadic}     ? (variadic     => 1) : ()),
            ($fn->{unannotated}  ? (unannotated  => 1) : ()),
        };

        if ($fn->{is_method}) {
            $registry->register_method($pkg, $name, $sig);
        } else {
            $registry->register_function($pkg, $name, $sig);
        }
    }
}

1;

=head1 NAME

Typist::Static::Registration - Type definition registration into Registry

=head1 DESCRIPTION

Registers extracted type definitions (from L<Typist::Static::Extractor>) into
a L<Typist::Registry> instance. Each C<register_*> method parses type
expressions and populates the registry with resolved types, constructors,
accessor methods, and effect operations.

All C<register_*> methods accept C<$extracted> (the Extractor result hashref),
C<$registry> (a L<Typist::Registry> instance), and optional C<%opts> with
C<errors> (a collector) and C<file> (filename for diagnostics).

=head2 register_all

    Typist::Static::Registration->register_all($extracted, $registry, %opts);

Registers all type definitions in dependency order: aliases, newtypes, structs,
datatypes, effects, typeclasses, instances, declares, and functions.

=head2 register_aliases

    Typist::Static::Registration->register_aliases($extracted, $registry, %opts);

Parses and registers C<typedef> alias definitions into the registry.

=head2 register_newtypes

    Typist::Static::Registration->register_newtypes($extracted, $registry, %opts);

Parses and registers C<newtype> definitions, creating both the newtype entry
and its constructor function (C<Name(Inner) -E<gt> Name>).

=head2 register_structs

    Typist::Static::Registration->register_structs($extracted, $registry, %opts);

Parses and registers C<struct> definitions, creating the struct type, its
constructor function, field accessor methods, and the C<with()> method.

=head2 register_datatypes

    Typist::Static::Registration->register_datatypes($extracted, $registry, %opts);

Parses and registers C<datatype> (ADT/GADT) definitions, creating the data type
and a constructor function for each variant.

=head2 register_effects

    Typist::Static::Registration->register_effects($extracted, $registry, %opts);

Registers C<effect> definitions with their operations, builds protocol objects
for stateful effects, and registers each operation as a qualified function with
its effect row annotation.

=head2 register_typeclasses

    Typist::Static::Registration->register_typeclasses($extracted, $registry, %opts);

Registers C<typeclass> definitions and their method signatures as generic
functions in the registry.

=head2 register_instances

    Typist::Static::Registration->register_instances($extracted, $registry, %opts);

Registers C<instance> declarations into the registry. Static registration uses
empty method maps; completeness checking is deferred to runtime.

=head2 register_declares

    Typist::Static::Registration->register_declares($extracted, $registry, %opts);

Parses and registers C<declare> statements, which provide type annotations for
external or builtin functions.

=head2 register_functions

    Typist::Static::Registration->register_functions($extracted, $registry, %opts);

Parses function signatures from C<:sig()> attributes and registers them in the
registry. Unannotated functions are registered with C<Any> parameter and return
types. Methods (C<$self>/C<$class> first param) are registered via
C<register_method>.

=cut
