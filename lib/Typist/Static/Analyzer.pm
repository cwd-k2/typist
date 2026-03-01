package Typist::Static::Analyzer;
use v5.40;

use Typist::Static::Extractor;
use Typist::Static::TypeChecker;
use Typist::Static::EffectChecker;
use Typist::Registry;
use Typist::Parser;
use Typist::Type::Eff;
use Typist::Type::Row;
use Typist::Static::Checker;
use Typist::Error;
use Typist::Attribute;
use Typist::Type::Newtype;
use Typist::Effect;
use Typist::TypeClass;
use Typist::Prelude;
use Typist::Type::Data;
use Typist::Type::Var;
use Typist::Type::Param;
use Typist::Type::Atom;
use Typist::Type::Alias;

# ── Severity Mapping ─────────────────────────────

my %SEVERITY = (
    CycleError       => 1,  # critical — breaks resolution
    TypeError        => 2,
    TypeMismatch     => 2,
    ArityMismatch    => 2,
    ResolveError     => 2,
    UndeclaredTypeVar => 3,
    EffectMismatch   => 2,
    UndeclaredRowVar => 3,
    UnknownEffect    => 3,
    UnknownTypeClass => 2,
    UnknownType      => 4,
);

# ── Public API ───────────────────────────────────

# Analyze a Perl source string for Typist type errors.
# Options:
#   workspace_registry => Typist::Registry instance with external typedefs
#   file               => filename for diagnostics
sub analyze ($class, $source, %opts) {
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    my $errors    = Typist::Error->collector;
    my $file      = $opts{file} // '(buffer)';

    # 1. Import workspace-level aliases
    if ($opts{workspace_registry}) {
        $registry->merge($opts{workspace_registry});
    }

    # 1b. Install builtin type prelude (CORE:: defaults)
    Typist::Prelude->install($registry);

    # 2. Register this file's typedefs
    for my $name (sort keys $extracted->{aliases}->%*) {
        my $info = $extracted->{aliases}{$name};
        my $parsed = eval { Typist::Parser->parse($info->{expr}) };
        if ($@) {
            $errors->collect(
                kind    => 'ResolveError',
                message => "Failed to parse typedef '$name': $@",
                file    => $file,
                line    => $info->{line},
            );
            next;
        }
        $registry->define_alias($name, $info->{expr});
    }

    # 2b. Register this file's newtypes
    for my $name (sort keys $extracted->{newtypes}->%*) {
        my $info = $extracted->{newtypes}{$name};
        my $inner = eval { Typist::Parser->parse($info->{inner_expr}) };
        if ($@) {
            $errors->collect(
                kind    => 'ResolveError',
                message => "Failed to parse newtype '$name': $@",
                file    => $file,
                line    => $info->{line},
            );
            next;
        }
        $registry->register_newtype($name, Typist::Type::Newtype->new($name, $inner));
    }

    # 2b-b. Register newtype constructors as functions
    for my $name (sort keys $extracted->{newtypes}->%*) {
        my $info = $extracted->{newtypes}{$name};
        my $inner = eval { Typist::Parser->parse($info->{inner_expr}) };
        next unless $inner;
        $registry->register_function($extracted->{package}, $name, +{
            params       => [$inner],
            returns      => Typist::Type::Newtype->new($name, $inner),
            generics     => [],
            params_expr  => [$inner->to_string],
            returns_expr => $name,
        });
    }

    # 2c. Register this file's effects
    for my $name (sort keys $extracted->{effects}->%*) {
        $registry->register_effect($name, Typist::Effect->new(name => $name, operations => +{}));
    }

    # 2d. Register this file's typeclasses with full Def (parses superclass from var_spec)
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

    # 2d-b. Register typeclass methods as functions
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

            # Collect all free type variables from the method signature
            # (includes typeclass var + method-specific vars like A, B)
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

    # 2e. Register this file's declares (external function annotations)
    for my $name (sort keys $extracted->{declares}->%*) {
        my $decl = $extracted->{declares}{$name};
        my $ann = eval { Typist::Parser->parse_annotation($decl->{type_expr}) };
        if ($@) {
            $errors->collect(
                kind    => 'ResolveError',
                message => "Failed to parse declare type for '$name': $@",
                file    => $file,
                line    => $decl->{line},
            );
            next;
        }

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

    # 2f. Register this file's datatypes
    for my $name (sort keys(($extracted->{datatypes} // +{})->%*)) {
        my $info = $extracted->{datatypes}{$name};
        my @tp = ($info->{type_params} // [])->@*;
        my (%parsed_variants, %return_types);

        for my $tag (keys $info->{variants}->%*) {
            my ($types, $ret_expr) = Typist::Type::Data->parse_constructor_spec(
                $info->{variants}{$tag}, type_params => \@tp,
            );
            $parsed_variants{$tag} = $types;

            # GADT: record per-constructor return type
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

        # 2g. Register datatype constructors as functions
        for my $tag (keys %parsed_variants) {
            my $param_types = $parsed_variants{$tag};
            my $return_type;

            if (exists $return_types{$tag}) {
                # GADT: use the explicit per-constructor return type
                $return_type = $return_types{$tag};
            } elsif (@tp) {
                my @vars = map { Typist::Type::Var->new($_) } @tp;
                $return_type = Typist::Type::Param->new($name, @vars);
            } else {
                $return_type = $dt;
            }
            my @generics = map { +{ name => $_, bound_expr => undef } } @tp;
            $registry->register_function($extracted->{package}, $tag, +{
                params       => $param_types,
                returns      => $return_type,
                generics     => \@generics,
                params_expr  => [map { $_->to_string } @$param_types],
                returns_expr => $return_type->to_string,
            });
        }
    }

    # 3. Register this file's functions
    for my $name (sort keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};
        my $pkg = $extracted->{package};

        my @param_types;
        for my $expr ($fn->{params_expr}->@*) {
            my $t = eval { Typist::Parser->parse($expr) };
            if ($@) {
                $errors->collect(
                    kind    => 'ResolveError',
                    message => "Failed to parse param type '$expr' in $name: $@",
                    file    => $file,
                    line    => $fn->{line},
                );
                next;
            }
            push @param_types, $t;
        }

        my $return_type;
        if ($fn->{returns_expr}) {
            $return_type = eval { Typist::Parser->parse($fn->{returns_expr}) };
            if ($@) {
                $errors->collect(
                    kind    => 'ResolveError',
                    message => "Failed to parse return type '$fn->{returns_expr}' in $name: $@",
                    file    => $file,
                    line    => $fn->{line},
                );
            }
        }

        # Parse effect annotation
        my $effects;
        if ($fn->{unannotated}) {
            # Unannotated function → Eff(*): open row, any effect possible
            $effects = Typist::Type::Eff->new(
                Typist::Type::Row->new(labels => [], row_var => '*'),
            );
        }
        elsif ($fn->{eff_expr}) {
            $effects = eval {
                my $row = Typist::Parser->parse_row($fn->{eff_expr});
                Typist::Type::Eff->new($row);
            };
            if ($@) {
                $errors->collect(
                    kind    => 'ResolveError',
                    message => "Failed to parse effect annotation '$fn->{eff_expr}' in $name: $@",
                    file    => $file,
                    line    => $fn->{line},
                );
            }
        }

        # Parse generic declarations into structured form
        my @generics;
        if ($fn->{generics} && @{$fn->{generics}}) {
            my $spec = join(', ', $fn->{generics}->@*);
            @generics = Typist::Attribute->parse_generic_decl($spec, registry => $registry);
        }

        my $sig = +{
            params   => \@param_types,
            returns  => $return_type,
            generics => \@generics,
            effects  => $effects,
        };

        if ($fn->{is_method}) {
            $registry->register_method($pkg, $name, $sig);
        } else {
            $registry->register_function($pkg, $name, $sig);
        }
    }

    # 4. Run Checker
    my $checker = Typist::Static::Checker->new(
        registry  => $registry,
        errors    => $errors,
        extracted => $extracted,
        file      => $file,
    );
    $checker->analyze;

    # 4.5. Run TypeChecker (static type mismatch detection)
    my $type_checker = Typist::Static::TypeChecker->new(
        registry  => $registry,
        errors    => $errors,
        extracted => $extracted,
        ppi_doc   => $extracted->{ppi_doc},
        file      => $file,
    );
    $type_checker->analyze;

    # 4.6. Run Effect Checker (static effect mismatch detection)
    my $effect_checker = Typist::Static::EffectChecker->new(
        registry  => $registry,
        errors    => $errors,
        extracted => $extracted,
        ppi_doc   => $extracted->{ppi_doc},
        file      => $file,
    );
    $effect_checker->analyze;

    # 5. Build results
    return +{
        diagnostics => _to_diagnostics($errors, $file, $extracted),
        symbols     => _build_symbol_index($extracted, $type_checker->env),
        extracted   => $extracted,
        registry    => $registry,
    };
}

# ── Diagnostic Conversion ───────────────────────

sub _to_diagnostics ($errors, $default_file, $extracted) {
    my $ignore = $extracted->{ignore_lines} // +{};
    my @diags;

    for my $err ($errors->errors) {
        my $line = $err->line;
        my $file = $err->file;

        # Regex fallback: enrich with location from extracted data
        # when the error lacks a resolved source position.
        my $needs_enrich = $line == 0 || $file =~ /\A\(/;

        if ($needs_enrich && ($file eq '(alias definition)' || $file eq '(type expression)')) {
            if ($err->message =~ /'(\w+)'/) {
                my $name = $1;
                if (my $info = $extracted->{aliases}{$name}) {
                    $line = $info->{line};
                    $file = $default_file;
                }
            }
        }
        if ($needs_enrich && ($file eq '(function signature)' || $file eq '(effect annotation)')) {
            if ($err->message =~ /in (?:\w+::)*(\w+)/) {
                my $fn_name = $1;
                if (my $info = $extracted->{functions}{$fn_name}) {
                    $line = $info->{line};
                    $file = $default_file;
                }
            }
        }

        if ($needs_enrich && $file eq '(typeclass definition)') {
            if ($err->message =~ /'(\w+)'/) {
                my $name = $1;
                if (my $info = $extracted->{typeclasses}{$name}) {
                    $line = $info->{line};
                    $file = $default_file;
                }
            }
        }

        # (type expression) errors: try alias first, then function context
        if ($needs_enrich && $file eq '(type expression)' && $line == 0) {
            if ($err->message =~ /in (?:\w+::)*(\w+)/) {
                my $fn_name = $1;
                if (my $info = $extracted->{functions}{$fn_name}) {
                    $line = $info->{line};
                    $file = $default_file;
                }
            }
        }

        # @typist-ignore: suppress diagnostics on ignored lines
        next if $ignore->{$line};

        push @diags, +{
            line     => $line,
            col      => 1,
            message  => $err->message,
            kind     => $err->kind,
            severity => $SEVERITY{$err->kind} // 3,
            file     => $file,
        };
    }

    \@diags;
}

# ── Symbol Index ─────────────────────────────────

sub _build_symbol_index ($extracted, $env = undef) {
    my @symbols;

    # Aliases
    for my $name (sort keys $extracted->{aliases}->%*) {
        my $info = $extracted->{aliases}{$name};
        push @symbols, +{
            name => $name,
            kind => 'typedef',
            type => $info->{expr},
            line => $info->{line},
            col  => $info->{col},
        };
    }

    # Variables
    for my $var ($extracted->{variables}->@*) {
        my $type     = $var->{type_expr};
        my $inferred = 0;

        # For unannotated variables, show inferred type from env
        if (!$type && $env && $env->{variables}{$var->{name}}) {
            $type     = $env->{variables}{$var->{name}}->to_string;
            $inferred = 1;
        }

        next unless $type;

        push @symbols, +{
            name     => $var->{name},
            kind     => 'variable',
            type     => $type,
            inferred => $inferred,
            line     => $var->{line},
            col      => $var->{col},
        };
    }

    # Functions
    for my $name (sort keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};

        # Unannotated functions: show !Eff(*) to indicate any-effect
        my $eff = $fn->{eff_expr};
        $eff = $fn->{unannotated} ? 'Eff(*)' : $eff && "Eff($eff)";

        push @symbols, +{
            name        => $name,
            kind        => 'function',
            params_expr => $fn->{params_expr},
            returns_expr => $fn->{returns_expr},
            generics    => $fn->{generics},
            eff_expr    => $eff,
            line        => $fn->{line},
            col         => $fn->{col},
        };
    }

    # Declares (external function annotations)
    for my $name (sort keys $extracted->{declares}->%*) {
        my $decl = $extracted->{declares}{$name};
        my $ann = eval { Typist::Parser->parse_annotation($decl->{type_expr}) };
        next if $@;

        my $type = $ann->{type};
        my (@params_expr, $returns_expr, $eff_expr);

        if ($type->is_func) {
            @params_expr  = map { $_->to_string } $type->params;
            $returns_expr = $type->returns->to_string;
            $eff_expr     = $type->effects
                ? 'Eff(' . $type->effects->to_string . ')' : undef;
        } else {
            $returns_expr = $type->to_string;
        }

        push @symbols, +{
            name         => $decl->{func_name},
            kind         => 'function',
            params_expr  => \@params_expr,
            returns_expr => $returns_expr,
            generics     => $ann->{generics_raw},
            eff_expr     => $eff_expr,
            declared     => 1,
            line         => $decl->{line},
            col          => $decl->{col},
        };
    }

    # Parameters
    for my $name (sort keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};
        my $param_names = $fn->{param_names} // [];
        my $param_exprs = $fn->{params_expr} // [];

        for my $i (0 .. $#$param_names) {
            my $pname = $param_names->[$i];
            my $ptype = $param_exprs->[$i] // 'Any';

            push @symbols, +{
                name        => $pname,
                kind        => 'parameter',
                type        => $ptype,
                fn_name     => $name,
                line        => $fn->{line},
                col         => $fn->{col},
                scope_start => $fn->{line},
                scope_end   => $fn->{end_line},
            };
        }
    }

    # Newtypes
    for my $name (sort keys $extracted->{newtypes}->%*) {
        my $info = $extracted->{newtypes}{$name};
        push @symbols, +{
            name => $name,
            kind => 'newtype',
            type => $info->{inner_expr},
            line => $info->{line},
            col  => $info->{col},
        };
    }

    # Effects
    for my $name (sort keys $extracted->{effects}->%*) {
        my $info = $extracted->{effects}{$name};
        push @symbols, +{
            name => $name,
            kind => 'effect',
            line => $info->{line},
            col  => $info->{col},
        };
    }

    # Typeclasses
    for my $name (sort keys $extracted->{typeclasses}->%*) {
        my $info = $extracted->{typeclasses}{$name};
        push @symbols, +{
            name         => $name,
            kind         => 'typeclass',
            var_spec     => $info->{var_spec},
            method_names => $info->{method_names},
            line         => $info->{line},
            col          => $info->{col},
        };
    }

    # Datatypes (ADT/GADT)
    for my $name (sort keys(($extracted->{datatypes} // +{})->%*)) {
        my $info = $extracted->{datatypes}{$name};
        my @tp   = ($info->{type_params} // [])->@*;
        my @parts;
        for my $tag (sort keys $info->{variants}->%*) {
            my $spec = $info->{variants}{$tag};
            push @parts, ($spec && $spec =~ /\S/) ? "$tag$spec" : $tag;
        }
        push @symbols, +{
            name => $name,
            kind => 'datatype',
            type => join(' | ', @parts),
            line => $info->{line},
            col  => $info->{col},
        };

        # Constructor symbols for each variant
        for my $tag (sort keys $info->{variants}->%*) {
            my ($types, $ret_expr) = Typist::Type::Data->parse_constructor_spec(
                $info->{variants}{$tag}, type_params => \@tp,
            );
            my @params_expr = map { $_->to_string } @$types;
            my $returns_expr;
            if (defined $ret_expr) {
                $returns_expr = $ret_expr;
            } elsif (@tp) {
                $returns_expr = $name . '[' . join(', ', @tp) . ']';
            } else {
                $returns_expr = $name;
            }
            my @generics = @tp ? @tp : ();

            push @symbols, +{
                name         => $tag,
                kind         => 'function',
                params_expr  => \@params_expr,
                returns_expr => $returns_expr,
                generics     => \@generics,
                constructor  => 1,
                line         => $info->{line},
                col          => $info->{col},
            };
        }
    }

    # Typeclass method symbols
    for my $tc_name (sort keys $extracted->{typeclasses}->%*) {
        my $tc_info = $extracted->{typeclasses}{$tc_name};
        my $methods = $tc_info->{methods} // +{};

        for my $method_name (sort keys %$methods) {
            my $sig_str = $methods->{$method_name};
            my $ann = eval { Typist::Parser->parse_annotation($sig_str) };
            next unless $ann;
            my $type = $ann->{type};
            my (@params_expr, $returns_expr);
            if ($type->is_func) {
                @params_expr  = map { $_->to_string } $type->params;
                $returns_expr = $type->returns->to_string;
            } else {
                $returns_expr = $type->to_string;
            }

            # Collect free type variables for generics display
            my %seen;
            if ($type->is_func) {
                $seen{$_} = 1 for map { $_->free_vars } $type->params;
                if ($type->returns) { $seen{$_} = 1 for $type->returns->free_vars }
            } else {
                $seen{$_} = 1 for $type->free_vars;
            }
            my @generics = sort keys %seen;

            push @symbols, +{
                name         => $method_name,
                kind         => 'function',
                params_expr  => \@params_expr,
                returns_expr => $returns_expr,
                generics     => \@generics,
                line         => $tc_info->{line},
                col          => $tc_info->{col},
            };
        }
    }

    \@symbols;
}

1;
