package Typist::Attribute;
use v5.40;

our $VERSION = '0.01';

use B;

# Heavy dependencies loaded on-demand in _handle_scalar_attrs / _handle_code_attrs.
# This avoids ~40ms load penalty when no :sig() attributes are used.
my $_DEPS_LOADED;
sub _ensure_deps {
    return if $_DEPS_LOADED;
    require Typist::Parser;
    require Typist::Registry;
    require Typist::Inference;
    require Typist::Subtype;
    require Typist::Tie::Scalar;
    require Typist::Transform;
    require Typist::Type::Eff;
    require Typist::Kind;
    require Typist::KindChecker;
    $_DEPS_LOADED = 1;
}

# ── Public API ────────────────────────────────────

# Install attribute handlers into the caller's namespace.
sub install ($class, $target) {
    no strict 'refs';

    *{"${target}::MODIFY_SCALAR_ATTRIBUTES"} = \&_handle_scalar_attrs;
    *{"${target}::MODIFY_CODE_ATTRIBUTES"}   = \&_handle_code_attrs;

    # Silence "unhandled attribute" warnings
    *{"${target}::FETCH_SCALAR_ATTRIBUTES"} = sub { () };
    *{"${target}::FETCH_CODE_ATTRIBUTES"}   = sub { () };
}

# ── Scalar Attributes ────────────────────────────

sub _handle_scalar_attrs ($pkg, $ref, @attrs) {
    my @unhandled;

    for my $attr (@attrs) {
        if ($attr =~ /\Asig\((.+)\)\z/s) {
            _ensure_deps();
            my $type = Typist::Parser->parse($1);

            Typist::Registry->register_variable(+{
                ref  => $ref,
                type => $type,
                pkg  => $pkg,
            });

            if ($Typist::RUNTIME) {
                tie $$ref, 'Typist::Tie::Scalar',
                    type    => $type,
                    name    => "\$$ref",
                    pkg     => $pkg,
                    ref_key => "$ref";
            }
        } else {
            push @unhandled, $attr;
        }
    }

    @unhandled;
}

# ── Generic Declaration Parsing ──────────────────

# Parse a :Generic(...) specification into structured hashrefs.
# Shared between runtime Attribute handling and static Analyzer.
#   $spec: the string inside :Generic(...)
#   %opts: registry => $registry (defaults to Typist::Registry singleton)
# Returns: list of hashrefs with keys: name, bound_expr, is_row_var, var_kind, tc_constraints
sub parse_generic_decl ($class, $spec, %opts) {
    _ensure_deps();
    my @decls = Typist::Parser->parse_param_decls($spec);
    $class->classify_constraints(\@decls, %opts);
    @decls;
}

# Classify constraint_expr fields into bound_expr / tc_constraints.
# Mutates entries in-place: replaces constraint_expr with bound_expr and/or tc_constraints.
# Entries without constraint_expr get bound_expr => undef for backward compatibility.
sub classify_constraints ($class, $decls, %opts) {
    my $registry = $opts{registry} // 'Typist::Registry';
    for my $entry (@$decls) {
        my $expr = delete $entry->{constraint_expr};
        unless (defined $expr) {
            # Row/Kind entries already resolved; plain names need bound_expr => undef
            $entry->{bound_expr} //= undef unless $entry->{is_row_var} || $entry->{var_kind};
            next;
        }
        my @parts = split /\s*\+\s*/, $expr;
        my (@tc_parts, @bound_parts);
        for my $part (@parts) {
            if ($registry->lookup_typeclass($part)) {
                push @tc_parts, $part;
            } else {
                push @bound_parts, $part;
            }
        }
        $entry->{tc_constraints} = \@tc_parts if @tc_parts;
        $entry->{bound_expr} = join(' + ', @bound_parts) if @bound_parts;
        $entry->{bound_expr} //= undef;
    }
    @$decls;
}

# ── Code Attributes ──────────────────────────────

sub _handle_code_attrs ($pkg, $coderef, @attrs) {
    my @unhandled;

    for my $attr (@attrs) {
        if ($attr =~ /\Asig\((.+)\)\z/s) {
            _ensure_deps();
            my $ann = Typist::Parser->parse_annotation($1);
            my $type = $ann->{type};

            unless ($type->is_func) {
                push @unhandled, $attr;
                next;
            }

            # Parse generic declarations
            my @generics;
            if (@{$ann->{generics_raw}}) {
                @generics = __PACKAGE__->parse_generic_decl(
                    join(', ', @{$ann->{generics_raw}})
                );
            }

            # Extract components from the Func type
            my @param_types = $type->params;
            my $return_type = $type->returns;
            my $effects     = $type->effects
                ? Typist::Type::Eff->new($type->effects) : undef;

            # Multi-char type variable support: transform aliases → vars
            if (@generics) {
                my %var_names = map { $_->{name} => 1 } @generics;
                @param_types = map {
                    Typist::Transform->aliases_to_vars($_, \%var_names)
                } @param_types;
                $return_type = Typist::Transform->aliases_to_vars(
                    $return_type, \%var_names
                );
                $effects = Typist::Transform->aliases_to_vars($effects, \%var_names)
                    if $effects;
            }

            # Resolve Param nodes whose base is a registered generic struct
            # into instantiated Struct types (e.g. Param(ReportNode, [Int]) → Struct)
            @param_types = map {
                Typist::Transform->resolve_struct_params($_, 'Typist::Registry')
            } @param_types;
            $return_type = Typist::Transform->resolve_struct_params(
                $return_type, 'Typist::Registry'
            );

            my $sig = +{
                params   => \@param_types,
                returns  => $return_type,
                generics => \@generics,
                effects  => $effects,
                variadic => $type->variadic,
            };

            my $sub_name = _recover_name($coderef) // '(anonymous)';
            Typist::Registry->register_function($pkg, $sub_name, $sig);
            if ($Typist::RUNTIME) {
                if ($sig->{generics} && @{$sig->{generics}}) {
                    _wrap_sub_generic($coderef, $sig, $pkg, $sub_name);
                } else {
                    _wrap_sub_simple($coderef, $sig, $pkg, $sub_name);
                }
            }
        } else {
            push @unhandled, $attr;
        }
    }

    @unhandled;
}

# ── Sub Wrapping ─────────────────────────────────

# Shared return-value dispatch: invoke $original, check result against $return_type.
sub _dispatch_return ($original, $return_type, $pkg, $name, @args) {
    # Void return — no value to check
    if ($return_type && $return_type->is_atom && $return_type->name eq 'Void') {
        $original->(@args);
        return;
    }

    my @result;
    if (wantarray) {
        @result = $original->(@args);
    } elsif (defined wantarray) {
        $result[0] = $original->(@args);
    } else {
        $original->(@args);
        return;
    }

    if ($return_type) {
        my $retval = $result[0];
        unless ($return_type->contains($retval)) {
            my $got = defined $retval ? "'$retval'" : 'undef';
            die sprintf(
                "Typist: %s::%s — return expected %s, got %s\n",
                $pkg, $name, $return_type->to_string, $got,
            );
        }
    }

    wantarray ? @result : $result[0];
}

sub _wrap_sub_simple ($coderef, $sig, $pkg, $name) {
    my $original    = $coderef;
    my @ptypes      = $sig->{params} ? $sig->{params}->@* : ();
    my $return_type = $sig->{returns};
    my $is_variadic = $sig->{variadic};

    my $wrapper = sub {
        my @args = @_;

        if (@ptypes) {
            my $fixed_count = $is_variadic ? $#ptypes : scalar @ptypes;
            for my $i (0 .. $fixed_count - 1) {
                if ($i < @args) {
                    unless ($ptypes[$i]->contains($args[$i])) {
                        my $got = defined $args[$i] ? "'$args[$i]'" : 'undef';
                        die sprintf(
                            "Typist: %s::%s — param %d expected %s, got %s\n",
                            $pkg, $name, $i + 1, $ptypes[$i]->to_string, $got,
                        );
                    }
                }
            }

            if ($is_variadic && @ptypes) {
                my $rest_type = $ptypes[-1];
                for my $i ($fixed_count .. $#args) {
                    unless ($rest_type->contains($args[$i])) {
                        my $got = defined $args[$i] ? "'$args[$i]'" : 'undef';
                        die sprintf(
                            "Typist: %s::%s — variadic param %d expected %s, got %s\n",
                            $pkg, $name, $i + 1, $rest_type->to_string, $got,
                        );
                    }
                }
            }
        }

        _dispatch_return($original, $return_type, $pkg, $name, @args);
    };

    no strict 'refs';
    no warnings 'redefine';
    *{"${pkg}::${name}"} = $wrapper;
}

sub _wrap_sub_generic ($coderef, $sig, $pkg, $name) {
    my $original = $coderef;

    # Pre-parse bound expressions so the wrapper closure reuses cached types
    my %cached_bounds;
    for my $g ($sig->{generics}->@*) {
        if ($g->{bound_expr}) {
            $cached_bounds{$g->{name}} = Typist::Parser->parse($g->{bound_expr});
        }
    }

    my $wrapper = sub {
        my @args = @_;

        # Check parameter types with generic instantiation
        my @ptypes = $sig->{params} ? $sig->{params}->@* : ();
        my @arg_types = map { Typist::Inference->infer_value($_) } @args;
        my $b = Typist::Inference->instantiate($sig, \@arg_types);
        my %bindings = %$b;

        # Verify bounds and type class constraints
        for my $g ($sig->{generics}->@*) {
            my $var_name = $g->{name};
            next unless exists $bindings{$var_name};
            my $actual = $bindings{$var_name};

            if (my $bound = $cached_bounds{$var_name}) {
                unless (Typist::Subtype->is_subtype($actual, $bound)) {
                    die sprintf(
                        "Typist: %s::%s — type variable '%s' bound to %s, but requires <: %s\n",
                        $pkg, $name, $var_name, $actual->to_string, $bound->to_string,
                    );
                }
            }

            if ($g->{tc_constraints}) {
                for my $tc_name ($g->{tc_constraints}->@*) {
                    my $inst = Typist::Registry->resolve_instance($tc_name, $actual);
                    unless ($inst) {
                        die sprintf(
                            "Typist: %s::%s — no instance of %s for %s\n",
                            $pkg, $name, $tc_name, $actual->to_string,
                        );
                    }
                }
            }
        }

        my $is_variadic = $sig->{variadic};
        my $fixed_count = $is_variadic ? $#ptypes : scalar @ptypes;
        for my $i (0 .. $fixed_count - 1) {
            my $ptype = $ptypes[$i]->substitute(\%bindings);

            if ($i < @args) {
                unless ($ptype->contains($args[$i])) {
                    my $got = defined $args[$i] ? "'$args[$i]'" : 'undef';
                    die sprintf(
                        "Typist: %s::%s — param %d expected %s, got %s\n",
                        $pkg, $name, $i + 1, $ptype->to_string, $got,
                    );
                }
            }
        }

        if ($is_variadic && @ptypes) {
            my $rest_type = $ptypes[-1]->substitute(\%bindings);
            for my $i ($fixed_count .. $#args) {
                unless ($rest_type->contains($args[$i])) {
                    my $got = defined $args[$i] ? "'$args[$i]'" : 'undef';
                    die sprintf(
                        "Typist: %s::%s — variadic param %d expected %s, got %s\n",
                        $pkg, $name, $i + 1, $rest_type->to_string, $got,
                    );
                }
            }
        }

        my $rtype = $sig->{returns}
            ? $sig->{returns}->substitute(\%bindings)
            : undef;
        _dispatch_return($original, $rtype, $pkg, $name, @args);
    };

    no strict 'refs';
    no warnings 'redefine';
    *{"${pkg}::${name}"} = $wrapper;
}

# ── Name Recovery ────────────────────────────────

sub _recover_name ($coderef) {
    my $cv = B::svref_2object($coderef);
    return undef unless $cv->isa('B::CV');
    my $gv = $cv->GV;
    return undef unless $gv->isa('B::GV');
    my $name = $gv->NAME;
    $name && $name ne '__ANON__' ? $name : undef;
}

1;

=head1 NAME

Typist::Attribute - Attribute handlers and generic declaration parsing

=head1 SYNOPSIS

    use Typist::Attribute;

    # Install handlers into a package
    Typist::Attribute->install('MyPackage');

    # Parse a generic declaration (shared by runtime and static paths)
    my @generics = Typist::Attribute->parse_generic_decl(
        'T: Num, U', registry => $registry,
    );

=head1 DESCRIPTION

Installs C<MODIFY_SCALAR_ATTRIBUTES> and C<MODIFY_CODE_ATTRIBUTES>
handlers that process C<:sig(...)> annotations on variables and
subroutines. Handles type registration and, when runtime mode is
enabled, ties scalars and wraps subroutines for runtime enforcement.

C<parse_generic_decl> is the shared parser for generic type variable
declarations, used by both the runtime attribute path and the static
analyzer.

=head1 METHODS

=head2 install

    Typist::Attribute->install($target_package);

Installs attribute handlers into C<$target_package>.

=head2 parse_generic_decl

    my @generics = Typist::Attribute->parse_generic_decl($spec, %opts);

Parses a generic declaration string (e.g., C<"T: Num, U">) into a list
of hashrefs with keys: C<name>, C<bound_expr>, C<is_row_var>,
C<var_kind>, C<tc_constraints>. Accepts optional C<registry> for
type class lookup.

Delegates syntax to C<Typist::Parser-E<gt>parse_param_decls>, then
classifies constraints via C<classify_constraints>.

=head2 classify_constraints

    Typist::Attribute->classify_constraints(\@decls, registry => $registry);

Classifies C<constraint_expr> fields in the given declaration hashrefs
(as returned by C<Typist::Parser-E<gt>parse_param_decls>) into
C<bound_expr> and/or C<tc_constraints> using Registry lookup. Mutates
entries in-place.

=head1 SEE ALSO

L<Typist>, L<Typist::Parser>, L<Typist::Registry>

=cut
