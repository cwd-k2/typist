package Typist::Static::Analyzer;
use v5.40;

our $VERSION = '0.01';

use Typist::Static::Extractor;
use Typist::Static::TypeChecker;
use Typist::Static::EffectChecker;
use Typist::Static::ProtocolChecker;
use Typist::Static::Registration;
use Typist::Registry;
use Typist::Parser;
use Typist::Static::Checker;
use Typist::Error;
use Typist::Prelude;
use Typist::Type::Data;

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
    ProtocolMismatch => 2,
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

    # 2. Register all type definitions from this file
    Typist::Static::Registration->register_all(
        $extracted, $registry,
        errors => $errors,
        file   => $file,
    );

    # 3. Run Checker
    my $checker = Typist::Static::Checker->new(
        registry  => $registry,
        errors    => $errors,
        extracted => $extracted,
        file      => $file,
    );
    $checker->analyze;

    # 3b. Run TypeChecker (static type mismatch detection)
    my $type_checker = Typist::Static::TypeChecker->new(
        registry  => $registry,
        errors    => $errors,
        extracted => $extracted,
        ppi_doc   => $extracted->{ppi_doc},
        file      => $file,
    );
    $type_checker->analyze;

    # 3c. Run Effect Checker (static effect mismatch detection)
    my $effect_checker = Typist::Static::EffectChecker->new(
        registry  => $registry,
        errors    => $errors,
        extracted => $extracted,
        ppi_doc   => $extracted->{ppi_doc},
        file      => $file,
    );
    $effect_checker->analyze;

    # 3d. Run Protocol Checker (static protocol state-machine verification)
    my $protocol_checker = Typist::Static::ProtocolChecker->new(
        registry  => $registry,
        errors    => $errors,
        extracted => $extracted,
        ppi_doc   => $extracted->{ppi_doc},
        file      => $file,
    );
    $protocol_checker->analyze;

    # 4. Build results
    return +{
        diagnostics    => _to_diagnostics($errors, $file, $extracted),
        symbols        => _build_symbol_index($extracted, $type_checker->env, $type_checker),
        extracted      => $extracted,
        registry       => $registry,
        protocol_hints => $protocol_checker->hints,
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

        my $col = $err->col > 0 ? $err->col : 1;

        my %diag = (
            line     => $line,
            col      => $col,
            message  => $err->message,
            kind     => $err->kind,
            severity => $SEVERITY{$err->kind} // 3,
            file     => $file,
        );

        $diag{end_line}      = $err->end_line      if defined $err->end_line;
        $diag{end_col}       = $err->end_col        if defined $err->end_col;
        $diag{expected_type} = $err->expected_type   if defined $err->expected_type;
        $diag{actual_type}   = $err->actual_type     if defined $err->actual_type;
        $diag{related}       = $err->related         if defined $err->related;
        $diag{suggestions}   = $err->suggestions     if defined $err->suggestions;

        push @diags, \%diag;
    }

    \@diags;
}

# ── Symbol Index ─────────────────────────────────

sub _build_symbol_index ($extracted, $env = undef, $type_checker = undef) {
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

        # Fallback: unannotated variables with no inferrable type → Any
        my $unknown = 0;
        if (!$type) {
            $type     = 'Any';
            $inferred = 1;
            $unknown  = 1;
        }

        push @symbols, +{
            name     => $var->{name},
            kind     => 'variable',
            type     => $type,
            inferred => $inferred,
            ($unknown ? (unknown => 1) : ()),
            line     => $var->{line},
            col      => $var->{col},
        };
    }

    # Functions
    for my $name (sort keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};

        # Unannotated functions: show ![*] to indicate any-effect
        my $eff = $fn->{eff_expr};
        $eff = $fn->{unannotated} ? '[*]' : $eff && "[$eff]";

        push @symbols, +{
            name        => $name,
            kind        => 'function',
            params_expr => $fn->{params_expr},
            returns_expr => $fn->{returns_expr},
            generics    => $fn->{generics},
            eff_expr    => $eff,
            ($fn->{unannotated} ? (unannotated => 1) : ()),
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
                ? '[' . $type->effects->to_string . ']' : undef;
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
                ($fn->{unannotated} ? (unannotated => 1) : ()),
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
            name       => $name,
            kind       => 'effect',
            op_names   => $info->{op_names},
            operations => $info->{operations},
            protocol   => $info->{protocol},
            line       => $info->{line},
            col        => $info->{col},
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
            methods      => $info->{methods},
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
        my @variants;
        for my $tag (sort keys $info->{variants}->%*) {
            my $spec = $info->{variants}{$tag};
            push @variants, +{ tag => $tag, spec => $spec // '' };
        }

        push @symbols, +{
            name     => $name,
            kind     => 'datatype',
            type     => join(' | ', @parts),
            variants => \@variants,
            line     => $info->{line},
            col      => $info->{col},
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

    # Structs
    for my $name (sort keys(($extracted->{structs} // +{})->%*)) {
        my $info = $extracted->{structs}{$name};
        my $fields = $info->{fields} // +{};
        my @opt_names = ($info->{optional_fields} // [])->@*;
        my %opt_set = map { $_ => 1 } @opt_names;

        my @field_descs;
        for my $f (sort keys %$fields) {
            my $key = $opt_set{$f} ? "$f?" : $f;
            push @field_descs, "$key: $fields->{$f}";
        }

        push @symbols, +{
            name   => $name,
            kind   => 'struct',
            fields => \@field_descs,
            line   => $info->{line},
            col    => $info->{col},
        };
    }

    # Loop variables (inferred by TypeChecker)
    if ($type_checker && $type_checker->can('loop_var_types')) {
        my $lvt = $type_checker->loop_var_types;
        for my $key (sort keys %$lvt) {
            my $lv = $lvt->{$key};
            push @symbols, +{
                name        => $lv->{name},
                kind        => 'variable',
                type        => $lv->{type}->to_string,
                inferred    => 1,
                line        => $lv->{line},
                col         => $lv->{col},
                scope_start => $lv->{scope_start},
                scope_end   => $lv->{scope_end},
            };
        }
    }

    # Callback parameters (from match arms, HOF callbacks)
    if ($type_checker && $type_checker->can('callback_param_types')) {
        my $cpt = $type_checker->callback_param_types // [];
        for my $cp (@$cpt) {
            push @symbols, +{
                name        => $cp->{name},
                kind        => 'variable',
                type        => $cp->{type}->to_string,
                inferred    => 1,
                line        => $cp->{line},
                col         => $cp->{col},
                scope_start => $cp->{scope_start},
                scope_end   => $cp->{scope_end},
            };
        }
    }

    # Narrowed variables (from type narrowing in if/unless/early-return)
    if ($type_checker && $type_checker->can('narrowed_var_types')) {
        my $nvt = $type_checker->narrowed_var_types // [];
        for my $nv (@$nvt) {
            push @symbols, +{
                name        => $nv->{name},
                kind        => 'variable',
                type        => $nv->{type}->to_string,
                inferred    => 1,
                narrowed    => 1,
                scope_start => $nv->{scope_start},
                scope_end   => $nv->{scope_end},
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
