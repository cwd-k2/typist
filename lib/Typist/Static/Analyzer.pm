package Typist::Static::Analyzer;
use v5.40;

our $VERSION = '0.01';

use Typist::Static::Extractor;
use Typist::Static::TypeEnv;
use Typist::Static::TypeChecker;
use Typist::Static::EffectChecker;
use Typist::Static::ProtocolChecker;
use Typist::Static::Infer;
use Typist::Static::Registration;
use Typist::Registry;
use Typist::Parser;
use Typist::Static::Checker;
use Typist::Error;
use Typist::Prelude;
use Typist::Subtype;
use Typist::Type::Data;
use Typist::Static::SymbolInfo qw(
    sym_function sym_parameter sym_variable sym_typedef sym_newtype
    sym_effect sym_typeclass sym_datatype sym_struct
);

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
    ImportHint       => 4,  # hint — type used in :sig() but defining package not imported
    ProtocolMismatch => 2,
    GradualHint      => 5,  # opt-in hint — blame tracking for Any
);

# ── Public API ───────────────────────────────────

# Analyze a Perl source string for Typist type errors.
# Options:
#   workspace_registry => Typist::Registry instance with external typedefs
#   file               => filename for diagnostics
sub analyze ($class, $source, %opts) {
    Typist::Subtype->clear_cache;

    my $extracted = $opts{extracted} // Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    my $errors    = Typist::Error->collector;
    my $file      = $opts{file} // '(buffer)';

    # Phase 1: Import + Registration
    if ($opts{workspace_registry}) {
        $registry->merge($opts{workspace_registry});
    }
    Typist::Prelude->install($registry);
    Typist::Static::Registration->register_all(
        $extracted, $registry,
        errors => $errors,
        file   => $file,
    );

    # Phase 1b: Type visibility check (lint level)
    _check_type_visibility($extracted, $registry, $errors, $file);

    # Phase 2: Structural verification
    Typist::Static::Checker->new(
        registry  => $registry,
        errors    => $errors,
        extracted => $extracted,
        file      => $file,
    )->analyze;

    # Phase 3: Type environment construction
    my $type_env = Typist::Static::TypeEnv->new(
        registry  => $registry,
        extracted => $extracted,
        ppi_doc   => $extracted->{ppi_doc},
    );
    $type_env->build;

    # Phase 4: File-level checks
    # Scope callback param collector — reentrant-safe via local
    local $Typist::Static::Infer::_CALLBACK_CTX = { params => [], seen => {} };
    my $type_checker = Typist::Static::TypeChecker->new(
        type_env      => $type_env,
        errors        => $errors,
        extracted     => $extracted,
        file          => $file,
        gradual_hints => $opts{gradual_hints},
    );
    $type_checker->check_variables;
    $type_checker->check_assignments;
    $type_checker->check_call_sites;

    # Phase 5: Function-level checks (unified loop)
    my $effect_checker = Typist::Static::EffectChecker->new(
        registry  => $registry,
        errors    => $errors,
        extracted => $extracted,
        ppi_doc   => $extracted->{ppi_doc},
        file      => $file,
    );
    my $protocol_checker = Typist::Static::ProtocolChecker->new(
        registry  => $registry,
        errors    => $errors,
        extracted => $extracted,
        ppi_doc   => $extracted->{ppi_doc},
        file      => $file,
    );
    $effect_checker->_setup;
    $protocol_checker->_setup;

    for my $name (sort keys $extracted->{functions}->%*) {
        $type_checker->check_function_returns($name);
        $effect_checker->check_function($name);
        $protocol_checker->check_function($name);
    }
    $protocol_checker->check_handle_blocks;

    # Phase 6: Collection (LSP hints)
    $type_checker->collect_fn_return_types;
    $type_checker->collect_callback_params;
    my $inferred_effects = Typist::Static::EffectChecker->infer_effects($extracted, $registry);

    # Phase 7: Results
    return +{
        diagnostics         => _to_diagnostics($errors, $file, $extracted),
        symbols             => _build_symbol_index($extracted, $type_checker->env, $type_checker),
        extracted           => $extracted,
        registry            => $registry,
        protocol_hints      => $protocol_checker->hints,
        narrowed_accessors  => $type_checker->narrowed_accessor_types,
        inferred_effects    => $inferred_effects,
        inferred_fn_returns => $type_checker->inferred_fn_returns,
        infer_log           => $type_checker->infer_log,
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
        push @symbols, sym_typedef(
            name => $name,
            type => $info->{expr},
            line => $info->{line},
            col  => $info->{col},
        );
    }

    # Variables
    # Build dedup set from local_var_types (function-scoped re-inference)
    # to avoid duplicate inlay hints for the same variable at the same position.
    my %local_var_keys;
    if ($type_checker && $type_checker->can('local_var_types')) {
        %local_var_keys = map { $_ => 1 } keys($type_checker->local_var_types->%*);
    }

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

        # Skip if local_var_types has a scoped re-inference for this variable
        my $dedup_key = $var->{name} . ':' . $var->{line};
        next if $inferred && $local_var_keys{$dedup_key};

        push @symbols, sym_variable(
            name     => $var->{name},
            type     => $type,
            inferred => $inferred,
            ($unknown ? (unknown => 1) : ()),
            line     => $var->{line},
            col      => $var->{col},
        );
    }

    # Functions
    for my $name (sort keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};

        my $eff = $fn->{eff_expr} && "[$fn->{eff_expr}]";

        push @symbols, sym_function(
            name         => $name,
            params_expr  => $fn->{params_expr},
            returns_expr => $fn->{returns_expr},
            generics     => $fn->{generics},
            eff_expr     => $eff,
            ($fn->{unannotated} ? (unannotated => 1) : ()),
            line         => $fn->{line},
            col          => $fn->{col},
        );
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

        push @symbols, sym_function(
            name         => $decl->{func_name},
            params_expr  => \@params_expr,
            returns_expr => $returns_expr,
            generics     => $ann->{generics_raw},
            eff_expr     => $eff_expr,
            declared     => 1,
            line         => $decl->{line},
            col          => $decl->{col},
        );
    }

    # Parameters
    for my $name (sort keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};
        my $param_names = $fn->{param_names} // [];
        my $param_exprs = $fn->{params_expr} // [];

        for my $i (0 .. $#$param_names) {
            my $pname = $param_names->[$i];
            my $ptype = $param_exprs->[$i] // 'Any';

            push @symbols, sym_parameter(
                name        => $pname,
                type        => $ptype,
                fn_name     => $name,
                ($fn->{unannotated} ? (unannotated => 1) : ()),
                line        => $fn->{line},
                col         => $fn->{col},
                scope_start => $fn->{line},
                scope_end   => $fn->{end_line},
            );
        }
    }

    # Newtypes
    for my $name (sort keys $extracted->{newtypes}->%*) {
        my $info = $extracted->{newtypes}{$name};
        push @symbols, sym_newtype(
            name => $name,
            type => $info->{inner_expr},
            line => $info->{line},
            col  => $info->{col},
        );
    }

    # Effects
    for my $name (sort keys $extracted->{effects}->%*) {
        my $info = $extracted->{effects}{$name};
        push @symbols, sym_effect(
            name       => $name,
            op_names   => $info->{op_names},
            operations => $info->{operations},
            protocol   => $info->{protocol},
            line       => $info->{line},
            col        => $info->{col},
        );
    }

    # Typeclasses
    for my $name (sort keys $extracted->{typeclasses}->%*) {
        my $info = $extracted->{typeclasses}{$name};
        push @symbols, sym_typeclass(
            name         => $name,
            var_spec     => $info->{var_spec},
            method_names => $info->{method_names},
            methods      => $info->{methods},
            line         => $info->{line},
            col          => $info->{col},
        );
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

        push @symbols, sym_datatype(
            name        => $name,
            type        => join(' | ', @parts),
            variants    => \@variants,
            type_params => \@tp,
            line        => $info->{line},
            col         => $info->{col},
        );

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

            push @symbols, sym_function(
                name         => $tag,
                params_expr  => \@params_expr,
                returns_expr => $returns_expr,
                generics     => \@generics,
                constructor  => 1,
                line         => $info->{line},
                col          => $info->{col},
            );
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

        push @symbols, sym_struct(
            name   => $name,
            fields => \@field_descs,
            line   => $info->{line},
            col    => $info->{col},
        );
    }

    # Loop variables (inferred by TypeChecker)
    if ($type_checker && $type_checker->can('loop_var_types')) {
        my $lvt = $type_checker->loop_var_types;
        for my $key (sort keys %$lvt) {
            my $lv = $lvt->{$key};
            push @symbols, sym_variable(
                name        => $lv->{name},
                type        => $lv->{type}->to_string,
                inferred    => 1,
                line        => $lv->{line},
                col         => $lv->{col},
                scope_start => $lv->{scope_start},
                scope_end   => $lv->{scope_end},
            );
        }
    }

    # Local variables (re-inferred with function-scoped env)
    if ($type_checker && $type_checker->can('local_var_types')) {
        my $lvt = $type_checker->local_var_types;
        for my $key (sort keys %$lvt) {
            my $lv = $lvt->{$key};
            push @symbols, sym_variable(
                name        => $lv->{name},
                type        => $lv->{type}->to_string,
                inferred    => 1,
                line        => $lv->{line},
                col         => $lv->{col},
                scope_start => $lv->{scope_start},
                scope_end   => $lv->{scope_end},
            );
        }
    }

    # Callback parameters (from match arms, HOF callbacks)
    if ($type_checker && $type_checker->can('callback_param_types')) {
        my $cpt = $type_checker->callback_param_types // [];
        for my $cp (@$cpt) {
            push @symbols, sym_variable(
                name        => $cp->{name},
                type        => $cp->{type}->to_string,
                inferred    => 1,
                line        => $cp->{line},
                col         => $cp->{col},
                scope_start => $cp->{scope_start},
                scope_end   => $cp->{scope_end},
            );
        }
    }

    # Narrowed variables (from type narrowing in if/unless/early-return)
    if ($type_checker && $type_checker->can('narrowed_var_types')) {
        my $nvt = $type_checker->narrowed_var_types // [];
        for my $nv (@$nvt) {
            push @symbols, sym_variable(
                name        => $nv->{name},
                type        => $nv->{type}->to_string,
                inferred    => 1,
                narrowed    => 1,
                scope_start => $nv->{scope_start},
                scope_end   => $nv->{scope_end},
            );
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

            push @symbols, sym_function(
                name         => $method_name,
                params_expr  => \@params_expr,
                returns_expr => $returns_expr,
                generics     => \@generics,
                line         => $tc_info->{line},
                col          => $tc_info->{col},
            );
        }
    }

    \@symbols;
}

# ── Type Visibility Check ────────────────────────

sub _check_type_visibility ($extracted, $registry, $errors, $file) {
    my $pkg = $extracted->{package} // 'main';

    # Collect type names used in annotations → first occurrence line
    my %seen;

    # Function signatures
    for my $name (keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};
        my $line = $fn->{line};
        for my $p (($fn->{params_expr} // [])->@*) {
            _collect_type_names($p, $line, \%seen);
        }
        _collect_type_names($fn->{returns_expr}, $line, \%seen);
        _collect_type_names($fn->{eff_expr}, $line, \%seen);
    }

    # Variable annotations
    for my $var ($extracted->{variables}->@*) {
        _collect_type_names($var->{type_expr}, $var->{line}, \%seen);
    }

    # Type definitions (aliases, newtypes, structs, effects)
    for my $info (values $extracted->{aliases}->%*) {
        _collect_type_names($info->{expr}, $info->{line}, \%seen);
    }
    for my $info (values $extracted->{newtypes}->%*) {
        _collect_type_names($info->{inner_expr}, $info->{line}, \%seen);
    }
    for my $info (values(($extracted->{structs} // +{})->%*)) {
        my $fields = $info->{fields} // +{};
        for my $ftype (values %$fields) {
            _collect_type_names($ftype, $info->{line}, \%seen);
        }
    }

    # Check visibility
    for my $type_name (sort keys %seen) {
        my $definer = $registry->defined_in($type_name);
        next unless defined $definer;                            # builtins / no provenance
        next if $registry->is_type_visible($type_name, $pkg);

        $errors->collect(
            kind    => 'ImportHint',
            message => "Type '$type_name' (defined in $definer) used but '$definer' is not imported",
            file    => $file,
            line    => $seen{$type_name},
            col     => 1,
        );
    }
}

sub _collect_type_names ($expr, $line, $map) {
    return unless defined $expr && length $expr;
    while ($expr =~ /\b([A-Z][A-Za-z0-9_]*)\b/g) {
        $map->{$1} //= $line;
    }
}

1;

=head1 NAME

Typist::Static::Analyzer - Static analysis pipeline for Typist source code

=head1 DESCRIPTION

Orchestrates the full static analysis pipeline: extraction, registration,
structural checking, type checking, effect checking, and protocol verification.
Returns a result hashref containing diagnostics, symbols, and inferred metadata.

=head2 analyze

    my $result = Typist::Static::Analyzer->analyze($source, %opts);

Analyzes a Perl source string for Typist type errors. Runs the complete
pipeline: L<Typist::Static::Extractor>, L<Typist::Static::Registration>,
L<Typist::Static::Checker>, L<Typist::Static::TypeChecker>,
L<Typist::Static::EffectChecker>, and L<Typist::Static::ProtocolChecker>.

Options:

=over 4

=item C<workspace_registry> - A L<Typist::Registry> instance with external type definitions to merge.

=item C<file> - Filename for diagnostic messages (defaults to C<(buffer)>).

=item C<extracted> - Pre-extracted result from L<Typist::Static::Extractor> (skips re-extraction).

=back

Returns a hashref with keys: C<diagnostics>, C<symbols>, C<extracted>,
C<registry>, C<protocol_hints>, C<narrowed_accessors>, C<inferred_effects>,
and C<inferred_fn_returns>.

=cut
