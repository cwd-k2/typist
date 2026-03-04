package Typist::Algebra;
use v5.40;

use Scalar::Util 'blessed';

our $VERSION = '0.01';

# Algebraic data types: datatype, enum, match.
# Extracted from Typist.pm for module decomposition.

# ── Datatype Support (Tagged Union / ADT) ──────

sub _datatype ($caller, $name_spec, %variants) {
    # Parse name and type parameters: 'Name[T, U]' or plain 'Name'
    my ($name, @raw);
    ($name, @raw) = Typist::Parser->parse_parameterized_name($name_spec);
    my @type_params = map { s/\s//gr } @raw;

    my %var_names = map { $_ => 1 } @type_params;
    my (%parsed_variants, %return_types);

    for my $tag (keys %variants) {
        my ($types, $ret_expr) = Typist::Type::Data->parse_constructor_spec(
            $variants{$tag}, type_params => \@type_params,
        );
        $parsed_variants{$tag} = $types;

        # GADT: parse and record per-constructor return type
        my $forced_args;  # arrayref of forced type args for GADT, undef for normal
        if (defined $ret_expr) {
            my $ret_type = Typist::Parser->parse($ret_expr);
            $return_types{$tag} = $ret_type;
            # Extract forced type arguments from return type (e.g., Expr[Int] → [Int])
            if ($ret_type->is_param) {
                $forced_args = [$ret_type->params];
            }
        }

        # Install constructor function into caller's namespace
        my @captured_types = @$types;
        my $tag_copy   = $tag;
        my $data_class = "Typist::Data::${name}";
        my @tp = @type_params;
        my $fa = $forced_args;
        no strict 'refs';
        *{"${caller}::${tag_copy}"} = sub (@args) {
            die("${tag_copy}(): expected "
                . scalar(@captured_types)
                . " arguments, got "
                . scalar(@args) . "\n")
                unless @args == @captured_types;

            if (@tp) {
                # Parameterized: infer type args, then validate
                my %bindings;
                for my $i (0 .. $#captured_types) {
                    my $formal = $captured_types[$i];
                    next unless $formal->is_var && $var_names{$formal->name};
                    my $inferred = Typist::Inference->infer_value($args[$i]);
                    if (exists $bindings{$formal->name}) {
                        $bindings{$formal->name} = Typist::Subtype->common_super(
                            $bindings{$formal->name}, $inferred,
                        );
                    } else {
                        $bindings{$formal->name} = $inferred;
                    }
                }
                for my $i (0 .. $#captured_types) {
                    my $exp = %bindings
                        ? $captured_types[$i]->substitute(\%bindings)
                        : $captured_types[$i];
                    unless ($exp->contains($args[$i])) {
                        die("${tag_copy}(): argument "
                            . ($i + 1) . " expected "
                            . $exp->to_string . ", got $args[$i]\n");
                    }
                }

                # GADT: forced type args override inferred ones
                my @type_args;
                if ($fa) {
                    for my $i (0 .. $#tp) {
                        my $f = $fa->[$i];
                        if ($f && !$f->is_var) {
                            push @type_args, $f;  # forced by GADT constraint
                        } else {
                            push @type_args,
                                $bindings{$tp[$i]} // Typist::Type::Atom->new('Any');
                        }
                    }
                } else {
                    @type_args = map {
                        $bindings{$_} // Typist::Type::Atom->new('Any')
                    } @tp;
                }

                bless +{
                    _tag       => $tag_copy,
                    _values    => \@args,
                    _type_args => \@type_args,
                }, $data_class;
            } else {
                # Non-parameterized: validate directly
                for my $i (0 .. $#captured_types) {
                    unless ($captured_types[$i]->contains($args[$i])) {
                        die("${tag_copy}(): argument "
                            . ($i + 1) . " expected "
                            . $captured_types[$i]->to_string
                            . ", got $args[$i]\n");
                    }
                }
                bless +{ _tag => $tag_copy, _values => \@args }, $data_class;
            }
        };
    }

    my $data_type = Typist::Type::Data->new($name, \%parsed_variants,
        type_params  => \@type_params,
        return_types => (%return_types ? \%return_types : +{}),
    );
    Typist::Registry->register_datatype($name, $data_type);

    # Register constructor functions so CHECK-phase cross-file inference
    # can resolve calls like Ok(1), Some(v), None() from other packages.
    for my $tag (keys %parsed_variants) {
        my $param_types = $parsed_variants{$tag};
        my $return_type;
        if (exists $return_types{$tag}) {
            $return_type = $return_types{$tag};
        } elsif (@type_params) {
            my @vars = map { Typist::Type::Var->new($_) } @type_params;
            $return_type = Typist::Type::Param->new($name, @vars);
        } else {
            $return_type = $data_type;
        }
        my @generics = map { +{ name => $_, bound_expr => undef } } @type_params;
        Typist::Registry->register_function($caller, $tag, +{
            params    => $param_types,
            returns   => $return_type,
            generics  => \@generics,
            constructor => 1,
        });
    }
}

# ── Enum Support (nullary ADT sugar) ─────────────

sub _enum ($caller, $name, @tags) {
    my %parsed_variants;
    my $data_class = "Typist::Data::${name}";
    for my $tag (@tags) {
        $parsed_variants{$tag} = [];
        my $tag_copy = $tag;
        no strict 'refs';
        *{"${caller}::${tag_copy}"} = sub () {
            bless +{ _tag => $tag_copy, _values => [] }, $data_class;
        };
    }
    my $data_type = Typist::Type::Data->new($name, \%parsed_variants);
    Typist::Registry->register_datatype($name, $data_type);

    # Register constructor functions for CHECK-phase cross-file inference.
    for my $tag (@tags) {
        Typist::Registry->register_function($caller, $tag, +{
            params      => [],
            returns     => $data_type,
            generics    => [],
            constructor => 1,
        });
    }
}

# ── Match Support (ADT pattern dispatch) ─────────

sub _match ($value, %arms) {
    my $tag = $value->{_tag}
        // die "Typist: match — value has no _tag\n";

    # Exhaustiveness: warn if known ADT has uncovered variants (no fallback _)
    if (!exists $arms{_} && blessed($value)) {
        my $class = blessed($value);
        if ($class =~ /\ATypist::Data::(\w+)\z/) {
            my $dt = Typist::Registry->lookup_datatype($1);
            if ($dt) {
                my @missing = grep { !exists $arms{$_} }
                    sort keys $dt->variants->%*;
                warn "Typist: match — non-exhaustive pattern: missing "
                    . join(', ', @missing) . "\n"
                    if @missing;
            }
        }
    }

    my $handler = $arms{$tag} // $arms{_}
        // die "Typist: match — no arm for tag '$tag' and no fallback '_'\n";

    $handler->($value->{_values} ? $value->{_values}->@* : ());
}

1;
