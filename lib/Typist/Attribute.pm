package Typist::Attribute;
use v5.40;

use B;
use Typist::Parser;
use Typist::Registry;
use Typist::Inference;
use Typist::Subtype;
use Typist::Tie::Scalar;
use Typist::Transform;

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
        if ($attr =~ /\AType\((.+)\)\z/) {
            my $type = Typist::Parser->parse($1);

            Typist::Registry->register_variable(+{
                ref  => $ref,
                type => $type,
                pkg  => $pkg,
            });

            tie $$ref, 'Typist::Tie::Scalar',
                type => $type,
                name => "\$$ref",
                pkg  => $pkg;
        } else {
            push @unhandled, $attr;
        }
    }

    @unhandled;
}

# ── Code Attributes ──────────────────────────────

sub _handle_code_attrs ($pkg, $coderef, @attrs) {
    my @unhandled;
    my (@params_expr, $returns_expr, @generics);

    for my $attr (@attrs) {
        if ($attr =~ /\AParams\((.+)\)\z/) {
            @params_expr = split /\s*,\s*/, $1;
        }
        elsif ($attr =~ /\AReturns\((.+)\)\z/) {
            $returns_expr = $1;
        }
        elsif ($attr =~ /\AGeneric\((.+)\)\z/) {
            for my $decl (split /\s*,\s*/, $1) {
                if ($decl =~ /\A(\w+)\s*:\s*(.+)\z/) {
                    my ($vname, $constraint) = ($1, $2);
                    # Check if constraints are type class names (possibly '+' separated)
                    my @parts = split /\s*\+\s*/, $constraint;
                    my @tc_constraints;
                    my $is_typeclass = 1;
                    for my $part (@parts) {
                        if (Typist::Registry->lookup_typeclass($part)) {
                            push @tc_constraints, $part;
                        } else {
                            $is_typeclass = 0;
                            last;
                        }
                    }
                    if ($is_typeclass && @tc_constraints) {
                        push @generics, +{
                            name          => $vname,
                            bound_expr    => undef,
                            tc_constraints => \@tc_constraints,
                        };
                    } else {
                        push @generics, +{ name => $vname, bound_expr => $constraint };
                    }
                } else {
                    push @generics, +{ name => $decl, bound_expr => undef };
                }
            }
        }
        else {
            push @unhandled, $attr;
        }
    }

    # Only proceed if we have type annotations
    if (@params_expr || $returns_expr) {
        my @param_types  = map { Typist::Parser->parse($_) } @params_expr;
        my $return_type  = $returns_expr ? Typist::Parser->parse($returns_expr) : undef;

        # Multi-char type variable support: transform aliases → vars
        if (@generics) {
            my %var_names = map { $_->{name} => 1 } @generics;
            @param_types = map { Typist::Transform->aliases_to_vars($_, \%var_names) } @param_types;
            $return_type = Typist::Transform->aliases_to_vars($return_type, \%var_names)
                if $return_type;
        }

        my $sig = +{
            params   => \@param_types,
            returns  => $return_type,
            generics => \@generics,
        };

        # Recover the subroutine name via B introspection
        my $sub_name = _recover_name($coderef) // '(anonymous)';

        Typist::Registry->register_function($pkg, $sub_name, $sig);

        # Wrap the original sub with type-checking via glob replacement
        _wrap_sub($coderef, $sig, $pkg, $sub_name);
    }

    @unhandled;
}

# ── Sub Wrapping ─────────────────────────────────

sub _wrap_sub ($coderef, $sig, $pkg, $name) {
    my $original = $coderef;

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

                    # Structural bound check
                    if ($g->{bound_expr}) {
                        my $bound = Typist::Parser->parse($g->{bound_expr});
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

            for my $i (0 .. $#ptypes) {
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
        }

        # Call original — always capture return value for type checking
        my $wantarray = wantarray;
        my @result = $original->(@args);

        # Check return type (regardless of calling context)
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

        $wantarray ? @result : $result[0];
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
