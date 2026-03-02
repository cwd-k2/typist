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
    $class->register_datatypes($extracted, $registry, %opts);
    $class->register_effects($extracted, $registry, %opts);
    $class->register_typeclasses($extracted, $registry, %opts);
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
            });
        }
    }
}

# ── Effects ──────────────────────────────────────

sub register_effects ($class, $extracted, $registry, %opts) {
    for my $name (sort keys $extracted->{effects}->%*) {
        my $eff_info = $extracted->{effects}{$name};
        my $ops = $eff_info->{operations} // +{};
        $registry->register_effect($name, Typist::Effect->new(name => $name, operations => $ops));

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

            my $eff_row = Typist::Type::Row->new(labels => [$name]);
            my $effects = Typist::Type::Eff->new($eff_row);

            $registry->register_function($name, $op_name, +{
                params       => \@params,
                returns      => $returns,
                generics     => [],
                effects      => $effects,
                params_expr  => [map { $_->to_string } @params],
                returns_expr => $returns->to_string,
            });
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
                name => $name,
                var  => $info->{var_spec} // 'T',
            );
        };
        $registry->register_typeclass($name, $def // undef);
    }

    # Register typeclass methods as functions
    for my $tc_name (sort keys $extracted->{typeclasses}->%*) {
        my $tc_info = $extracted->{typeclasses}{$tc_name};
        my $methods = $tc_info->{methods} // +{};

        for my $method_name (sort keys %$methods) {
            my $sig_str = $methods->{$method_name};
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
            params   => \@param_types,
            returns  => $return_type,
            generics => \@generics,
            effects  => $effects,
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
        };

        if ($fn->{is_method}) {
            $registry->register_method($pkg, $name, $sig);
        } else {
            $registry->register_function($pkg, $name, $sig);
        }
    }
}

1;
