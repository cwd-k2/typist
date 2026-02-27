package Typist::Attribute;
use v5.40;

use B;
use Typist::Parser;
use Typist::Registry;
use Typist::Inference;
use Typist::Subtype;
use Typist::Tie::Scalar;

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

            Typist::Registry->register_variable({
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
            @generics = split /\s*,\s*/, $1;
        }
        else {
            push @unhandled, $attr;
        }
    }

    # Only proceed if we have type annotations
    if (@params_expr || $returns_expr) {
        my @param_types  = map { Typist::Parser->parse($_) } @params_expr;
        my $return_type  = $returns_expr ? Typist::Parser->parse($returns_expr) : undef;

        my $sig = {
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

            # If generic, attempt instantiation
            if ($sig->{generics} && $sig->{generics}->@*) {
                my @arg_types = map { Typist::Inference->infer_value($_) } @args;
                my $b = Typist::Inference->instantiate($sig, \@arg_types);
                %bindings = %$b;
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
