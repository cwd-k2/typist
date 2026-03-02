package Typist::Attribute;
use v5.40;

our $VERSION = '0.01';

use B;
use Typist::Parser;
use Typist::Registry;
use Typist::Inference;
use Typist::Subtype;
use Typist::Tie::Scalar;
use Typist::Transform;
use Typist::Type::Eff;
use Typist::Kind;
use Typist::KindChecker;

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
        if ($attr =~ /\AType\((.+)\)\z/s) {
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
    my $registry = $opts{registry} // 'Typist::Registry';
    my @generics;

    for my $decl (split /\s*,\s*/, $spec) {
        if ($decl =~ /\A(\w+)\s*:\s*(.+)\z/) {
            my ($vname, $constraint) = ($1, $2);
            my @parts = split /\s*\+\s*/, $constraint;
            my @tc_constraints;
            my $is_typeclass = 1;
            for my $part (@parts) {
                if ($registry->lookup_typeclass($part)) {
                    push @tc_constraints, $part;
                } else {
                    $is_typeclass = 0;
                    last;
                }
            }
            if ($constraint eq 'Row') {
                push @generics, +{
                    name       => $vname,
                    bound_expr => undef,
                    is_row_var => 1,
                    var_kind   => Typist::Kind->Row,
                };
            } elsif ($constraint =~ /\A[\s\*\-\>]+\z/) {
                my $kind = Typist::Kind->parse($constraint);
                push @generics, +{
                    name       => $vname,
                    bound_expr => undef,
                    var_kind   => $kind,
                };
            } elsif ($is_typeclass && @tc_constraints) {
                push @generics, +{
                    name           => $vname,
                    bound_expr     => undef,
                    tc_constraints => \@tc_constraints,
                };
            } else {
                push @generics, +{ name => $vname, bound_expr => $constraint };
            }
        } else {
            push @generics, +{ name => $decl, bound_expr => undef };
        }
    }

    @generics;
}

# ── Code Attributes ──────────────────────────────

sub _handle_code_attrs ($pkg, $coderef, @attrs) {
    my @unhandled;

    for my $attr (@attrs) {
        if ($attr =~ /\AType\((.+)\)\z/s) {
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
                _wrap_sub($coderef, $sig, $pkg, $sub_name);
            }
        } else {
            push @unhandled, $attr;
        }
    }

    @unhandled;
}

# ── Sub Wrapping ─────────────────────────────────

sub _wrap_sub ($coderef, $sig, $pkg, $name) {
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
        my %bindings;

        # Check parameter types
        if ($sig->{params}) {
            my @ptypes = $sig->{params}->@*;

            # If generic, attempt instantiation + bound checking
            if ($sig->{generics} && @{$sig->{generics}}) {
                my @arg_types = map { Typist::Inference->infer_value($_) } @args;
                my $b = Typist::Inference->instantiate($sig, \@arg_types);
                %bindings = %$b;

                # Verify bounds and type class constraints
                for my $g ($sig->{generics}->@*) {
                    my $var_name = $g->{name};
                    next unless exists $bindings{$var_name};
                    my $actual = $bindings{$var_name};

                    # Structural bound check (using cached parse result)
                    if (my $bound = $cached_bounds{$var_name}) {
                        unless (Typist::Subtype->is_subtype($actual, $bound)) {
                            die sprintf(
                                "Typist: %s::%s — type variable '%s' bound to %s, but requires <: %s\n",
                                $pkg, $name, $var_name, $actual->to_string, $bound->to_string,
                            );
                        }
                    }

                    # Type class constraint check
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
            }

            my $is_variadic = $sig->{variadic};
            my $fixed_count = $is_variadic ? $#ptypes : @ptypes;
            for my $i (0 .. $fixed_count - 1) {
                my $ptype = $ptypes[$i];
                $ptype = $ptype->substitute(\%bindings) if %bindings;

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

            # Variadic: check remaining args against the last param type
            if ($is_variadic && @ptypes) {
                my $rest_type = $ptypes[-1];
                $rest_type = $rest_type->substitute(\%bindings) if %bindings;
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

        # Call original — propagate the caller's context
        my @result;
        if (wantarray) {
            @result = $original->(@args);
        } elsif (defined wantarray) {
            $result[0] = $original->(@args);
        } else {
            $original->(@args);
            return;
        }

        # Check return type
        if ($sig->{returns}) {
            my $rtype = $sig->{returns};

            if (%bindings) {
                $rtype = $rtype->substitute(\%bindings);
            }

            my $retval = $result[0];
            unless ($rtype->contains($retval)) {
                my $got = defined $retval ? "'$retval'" : 'undef';
                die sprintf(
                    "Typist: %s::%s — return expected %s, got %s\n",
                    $pkg, $name, $rtype->to_string, $got,
                );
            }
        }

        wantarray ? @result : $result[0];
    };

    # Install wrapper into the symbol table, replacing the original
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
handlers that process C<:Type(...)> annotations on variables and
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

=head1 SEE ALSO

L<Typist>, L<Typist::Parser>, L<Typist::Registry>

=cut
