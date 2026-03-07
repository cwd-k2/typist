package Typist::StructDef;
use v5.40;

our $VERSION = '0.01';

# Nominal struct type definitions.
# Extracted from Typist.pm for module decomposition.

sub _struct ($name_spec, $caller, @field_pairs) {
    die "Typist: struct '$name_spec' — odd number of field arguments\n"
        if @field_pairs % 2;

    # Parse name and type parameters: 'Pair[T, U]', 'NumBox[T: Num]', or plain 'Point'
    my ($name, @type_params, @raw_specs);
    ($name, @raw_specs) = Typist::Parser->parse_parameterized_name($name_spec);
    @type_params = map { /\A(\w+)/ ? $1 : $_ } @raw_specs;

    # Parse bounds and typeclass constraints from raw specs
    my (%bounds, %tc);
    if (@raw_specs) {
        my @generics = Typist::Attribute->parse_generic_decl(
            join(', ', @raw_specs), registry => 'Typist::Registry',
        );
        for my $g (@generics) {
            if ($g->{bound_expr}) {
                $bounds{$g->{name}} = Typist::Parser->parse($g->{bound_expr});
            }
            if ($g->{tc_constraints}) {
                $tc{$g->{name}} = $g->{tc_constraints};
            }
        }
    }

    my %var_names = map { $_ => 1 } @type_params;
    my %field_spec = @field_pairs;
    my (%required_types, %optional_types);

    for my $key (keys %field_spec) {
        my $val = $field_spec{$key};
        if ($key =~ /\A(.+)\?\z/) {
            $optional_types{$1} = Typist::Type->coerce($val);
        } else {
            $required_types{$key} = Typist::Type->coerce($val);
        }
    }

    my $record = Typist::Type::Record->from_parts(
        required => \%required_types,
        optional => \%optional_types,
    );

    my $pkg = "Typist::Struct::${name}";
    my %type_bounds;
    for my $param (keys %bounds) {
        $type_bounds{$param} = $bounds{$param}->to_string;
    }
    for my $param (keys %tc) {
        $type_bounds{$param} //= join(' + ', $tc{$param}->@*);
    }
    my $type = Typist::Type::Struct->new(
        name        => $name,
        record      => $record,
        package     => $pkg,
        type_params => \@type_params,
        type_bounds => \%type_bounds,
    );

    # 1. Register in Registry
    Typist::Registry->register_type($name, $type);

    # 2. Generate the package (ISA, meta, accessors)
    {
        no strict 'refs';
        my %all_types = (%required_types, %optional_types);
        my %req_copy  = %required_types;
        my %opt_copy  = %optional_types;
        my $meta = +{
            name     => $name,
            required => \%req_copy,
            optional => \%opt_copy,
        };
        *{"${pkg}::_typist_struct_meta"} = sub { $meta };

        # Accessors for each field
        for my $field (keys %all_types) {
            my $f = $field;  # capture
            *{"${pkg}::${f}"} = sub ($self) { $self->{$f} };
        }

        # Immutable derive: returns a new instance with specified fields changed.
        *{"${name}::derive"} = sub ($self, @args) {
            die "Typist: ${name}::derive — odd number of arguments\n"
                if @args % 2;
            my %updates = @args;
            for my $key (keys %updates) {
                die "Unknown field '$key' for struct $name\n"
                    unless exists $all_types{$key};
            }
            my %new = %$self;
            @new{keys %updates} = values %updates;
            bless \%new, ref $self;
        };
    }

    # 3. Install constructor in caller's namespace
    {
        my %req = %required_types;
        my %opt = %optional_types;
        my %all = (%req, %opt);
        my @tp  = @type_params;
        no strict 'refs';
        *{"${caller}::${name}"} = sub (@args) {
            die "Typist: ${name}() — odd number of arguments\n"
                if @args % 2;
            my %given = @args;

            # Check for unknown fields
            for my $k (keys %given) {
                die "Typist: ${name}() — unknown field '$k'\n"
                    unless exists $all{$k};
            }

            # Check required fields
            for my $k (keys %req) {
                die "Typist: ${name}() — missing required field '$k'\n"
                    unless exists $given{$k};
            }

            if (@tp) {
                # Parameterized: infer type args from field values, then validate
                my %bindings;
                for my $k (keys %given) {
                    my $formal = $all{$k};
                    next unless $formal->is_var && $var_names{$formal->name};
                    my $inferred = Typist::Inference->infer_value($given{$k});
                    if (exists $bindings{$formal->name}) {
                        $bindings{$formal->name} = Typist::Subtype->common_super(
                            $bindings{$formal->name}, $inferred,
                        );
                    } else {
                        $bindings{$formal->name} = $inferred;
                    }
                }
                # Bounded quantification check
                for my $param (keys %bounds) {
                    my $actual = $bindings{$param} // next;
                    unless (Typist::Subtype->is_subtype($actual, $bounds{$param})) {
                        die "Typist: ${name}() — type ${\$actual->to_string} does not satisfy bound ${\$bounds{$param}->to_string} for $param\n";
                    }
                }
                # Typeclass constraint check
                for my $param (keys %tc) {
                    my $actual = $bindings{$param} // next;
                    for my $tc_name ($tc{$param}->@*) {
                        unless (Typist::Registry->resolve_instance($tc_name, $actual)) {
                            die "Typist: ${name}() — no instance of $tc_name for ${\$actual->to_string}\n";
                        }
                    }
                }

                for my $k (keys %given) {
                    my $exp = %bindings
                        ? $all{$k}->substitute(\%bindings)
                        : $all{$k};
                    unless ($exp->contains($given{$k})) {
                        die "Typist: ${name}() — field '$k' expected "
                            . $exp->to_string . ", got $given{$k}\n";
                    }
                }

                my @type_args = map {
                    $bindings{$_} // Typist::Type::Atom->new('Any')
                } @tp;

                bless +{%given, _type_args => \@type_args}, $pkg;
            } else {
                # Non-parameterized: validate directly
                for my $k (keys %given) {
                    my $expected = $all{$k};
                    unless ($expected->contains($given{$k})) {
                        die "Typist: ${name}() — field '$k' expected "
                            . $expected->to_string . ", got $given{$k}\n";
                    }
                }

                bless +{%given}, $pkg;
            }
        };
    }

    # 4. Register constructor function so CHECK-phase cross-file inference
    #    can resolve calls like OrderItem(...) from other packages.
    my @generics = @raw_specs
        ? Typist::Attribute->parse_generic_decl(join(', ', @raw_specs), registry => 'Typist::Registry')
        : map { +{ name => $_, bound_expr => undef } } @type_params;
    Typist::Registry->register_function($caller, $name, +{
        params             => [],
        returns            => $type,
        generics           => \@generics,
        struct_constructor => 1,
    });
}

1;
