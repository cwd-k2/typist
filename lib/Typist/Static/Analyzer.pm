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

# ── Severity Mapping ─────────────────────────────

my %SEVERITY = (
    CycleError       => 1,  # critical — breaks resolution
    TypeError        => 2,
    TypeMismatch     => 2,
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

        $registry->register_function($pkg, $name, +{
            params   => \@param_types,
            returns  => $return_type,
            generics => \@generics,
            effects  => $effects,
        });
    }

    # 4. Run Checker
    my $checker = Typist::Static::Checker->new(registry => $registry, errors => $errors);
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
    my @diags;

    for my $err ($errors->errors) {
        my $line = $err->line;
        my $file = $err->file;

        # Enrich with location from extracted data when possible
        if ($file eq '(alias definition)' || $file eq '(type expression)') {
            if ($err->message =~ /'(\w+)'/) {
                my $name = $1;
                if (my $info = $extracted->{aliases}{$name}) {
                    $line = $info->{line};
                    $file = $default_file;
                }
            }
        }
        if ($file eq '(function signature)' || $file eq '(effect annotation)') {
            if ($err->message =~ /in (?:\w+::)*(\w+)/) {
                my $fn_name = $1;
                if (my $info = $extracted->{functions}{$fn_name}) {
                    $line = $info->{line};
                    $file = $default_file;
                }
            }
        }

        if ($file eq '(typeclass definition)') {
            if ($err->message =~ /'(\w+)'/) {
                my $name = $1;
                if (my $info = $extracted->{typeclasses}{$name}) {
                    $line = $info->{line};
                    $file = $default_file;
                }
            }
        }

        # (type expression) errors: try alias first, then function context
        if ($file eq '(type expression)' && $line == 0) {
            if ($err->message =~ /in (?:\w+::)*(\w+)/) {
                my $fn_name = $1;
                if (my $info = $extracted->{functions}{$fn_name}) {
                    $line = $info->{line};
                    $file = $default_file;
                }
            }
        }

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
        $eff = '*' if $fn->{unannotated};

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

    \@symbols;
}

1;
