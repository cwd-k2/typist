package Typist::LSP::Workspace;
use v5.40;

use File::Find;
use Typist::Registry;
use Typist::Static::Extractor;
use Typist::Parser;
use Typist::Type::Newtype;
use Typist::Type::Data;
use Typist::Type::Eff;
use Typist::Type::Row;
use Typist::Effect;
use Typist::Attribute;
use Typist::TypeClass;
use Typist::Prelude;
use Typist::Type::Var;
use Typist::Type::Param;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    my $self = bless +{
        root     => $args{root},
        registry => Typist::Registry->new,
        files    => +{},  # path -> +{ aliases, functions, newtypes, effects, typeclasses, package }
    }, $class;

    # Install builtin type prelude (CORE:: defaults)
    Typist::Prelude->install($self->{registry});

    $self->scan if $self->{root};
    $self;
}

# ── Accessors ────────────────────────────────────

sub registry ($self) { $self->{registry} }

# ── Initial Scan ─────────────────────────────────

sub scan ($self) {
    my $root = $self->{root};
    return unless $root && -d $root;

    my @pm_files;
    find(sub {
        return unless /\.pm\z/ && -f;
        push @pm_files, $File::Find::name;
    }, $root);

    for my $file (sort @pm_files) {
        $self->_index_file($file);
    }
}

# ── File Indexing ────────────────────────────────

sub _index_file ($self, $path) {
    open my $fh, '<:encoding(UTF-8)', $path or return;
    my $source = do { local $/; <$fh> };
    close $fh;

    my $extracted = eval { Typist::Static::Extractor->extract($source) };
    return if $@;

    $self->{files}{$path} = +{
        aliases     => $extracted->{aliases},
        functions   => $extracted->{functions},
        newtypes    => $extracted->{newtypes},
        datatypes   => $extracted->{datatypes},
        effects     => $extracted->{effects},
        typeclasses => $extracted->{typeclasses},
        declares    => $extracted->{declares},
        package     => $extracted->{package},
    };

    $self->_register_file_types($extracted);
}

# ── Incremental Update ──────────────────────────

sub update_file ($self, $path, $source) {
    if (exists $self->{files}{$path}) {
        delete $self->{files}{$path};
        $self->_rebuild_registry;
    }

    my $extracted = eval { Typist::Static::Extractor->extract($source) };
    return if $@;

    $self->{files}{$path} = +{
        aliases     => $extracted->{aliases},
        functions   => $extracted->{functions},
        newtypes    => $extracted->{newtypes},
        datatypes   => $extracted->{datatypes},
        effects     => $extracted->{effects},
        typeclasses => $extracted->{typeclasses},
        declares    => $extracted->{declares},
        package     => $extracted->{package},
    };

    $self->_register_file_types($extracted);
}

sub _register_file_types ($self, $extracted) {
    my $reg = $self->{registry};

    for my $name (keys $extracted->{aliases}->%*) {
        $reg->define_alias($name, $extracted->{aliases}{$name}{expr});
    }

    my $pkg = $extracted->{package} // 'main';

    for my $name (keys $extracted->{newtypes}->%*) {
        my $info = $extracted->{newtypes}{$name};
        my $inner = eval { Typist::Parser->parse($info->{inner_expr}) };
        next if $@;
        my $type = Typist::Type::Newtype->new($name, $inner);
        $reg->register_newtype($name, $type);

        # Register newtype constructor as a function: Name(Inner) -> Name
        $reg->register_function($pkg, $name, +{
            params       => [$inner],
            returns      => $type,
            generics     => [],
            params_expr  => [$inner->to_string],
            returns_expr => $name,
        });
    }

    my $datatypes = $extracted->{datatypes} // +{};
    for my $name (keys $datatypes->%*) {
        my $info = $extracted->{datatypes}{$name};
        my @tp = ($info->{type_params} // [])->@*;
        my (%parsed_variants, %return_types);

        for my $tag (keys $info->{variants}->%*) {
            my ($types, $ret_expr) = Typist::Type::Data->parse_constructor_spec(
                $info->{variants}{$tag}, type_params => \@tp,
            );
            $parsed_variants{$tag} = $types;

            if (defined $ret_expr) {
                my $ret_type = eval { Typist::Parser->parse($ret_expr) };
                $return_types{$tag} = $ret_type if $ret_type;
            }
        }

        my $type = Typist::Type::Data->new($name, \%parsed_variants,
            type_params  => \@tp,
            return_types => (%return_types ? \%return_types : +{}),
        );
        $reg->register_datatype($name, $type);

        # Register datatype constructors as functions
        for my $tag (keys %parsed_variants) {
            my $param_types = $parsed_variants{$tag};
            my $return_type;

            if (exists $return_types{$tag}) {
                $return_type = $return_types{$tag};
            } elsif (@tp) {
                my @vars = map { Typist::Type::Var->new($_) } @tp;
                $return_type = Typist::Type::Param->new($name, @vars);
            } else {
                $return_type = $type;
            }
            my @generics = map { +{ name => $_, bound_expr => undef } } @tp;
            $reg->register_function($pkg, $tag, +{
                params       => $param_types,
                returns      => $return_type,
                generics     => \@generics,
                params_expr  => [map { $_->to_string } @$param_types],
                returns_expr => $return_type->to_string,
            });
        }
    }

    for my $name (keys $extracted->{effects}->%*) {
        my $eff_info = $extracted->{effects}{$name};
        my $ops = $eff_info->{operations} // +{};
        my $eff = Typist::Effect->new(name => $name, operations => $ops);
        $reg->register_effect($name, $eff);

        # Register effect operations as functions
        for my $op_name (keys %$ops) {
            eval {
                my $ann = Typist::Parser->parse_annotation($ops->{$op_name});
                my $type = $ann->{type};
                my (@params, $returns);
                if ($type->is_func) {
                    @params  = $type->params;
                    $returns = $type->returns;
                } else {
                    $returns = $type;
                }

                my $eff_row = Typist::Type::Row->new(labels => [$name]);
                my $effects = Typist::Type::Eff->new($eff_row);

                $reg->register_function($name, $op_name, +{
                    params       => \@params,
                    returns      => $returns,
                    generics     => [],
                    effects      => $effects,
                    params_expr  => [map { $_->to_string } @params],
                    returns_expr => $returns->to_string,
                });
            };
        }
    }

    for my $name (keys $extracted->{typeclasses}->%*) {
        next if $reg->has_typeclass($name);
        my $info = $extracted->{typeclasses}{$name};
        my $def = eval {
            Typist::TypeClass->new_class(
                name => $name,
                var  => $info->{var_spec} // 'T',
            );
        };
        $reg->register_typeclass($name, $def // undef);
    }

    # Register typeclass methods as functions
    for my $tc_name (keys $extracted->{typeclasses}->%*) {
        my $tc_info = $extracted->{typeclasses}{$tc_name};
        my $methods = $tc_info->{methods} // +{};

        for my $method_name (keys %$methods) {
            my $sig_str = $methods->{$method_name};
            eval {
                my $ann = Typist::Parser->parse_annotation($sig_str);
                my $type = $ann->{type};
                my (@params, $returns);
                if ($type->is_func) {
                    @params  = $type->params;
                    $returns = $type->returns;
                } else {
                    $returns = $type;
                }

                my %seen;
                $seen{$_} = 1 for map { $_->free_vars } @params;
                if ($returns) { $seen{$_} = 1 for $returns->free_vars }
                my @generics = map { +{ name => $_, bound_expr => undef } } sort keys %seen;

                $reg->register_function($tc_name, $method_name, +{
                    params       => \@params,
                    returns      => $returns,
                    generics     => \@generics,
                    params_expr  => [map { $_->to_string } @params],
                    returns_expr => $returns->to_string,
                });
            };
        }
    }

    # Register declared external functions
    my $decls = $extracted->{declares} // +{};
    for my $name (keys $decls->%*) {
        my $decl = $decls->{$name};
        eval {
            my $ann = Typist::Parser->parse_annotation($decl->{type_expr});
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
                @generics = Typist::Attribute->parse_generic_decl($spec, registry => $reg);
            }

            $reg->register_function($decl->{package}, $decl->{func_name}, +{
                params   => \@param_types,
                returns  => $return_type,
                generics => \@generics,
                effects  => $effects,
            });
        };
    }

    # Register functions for cross-file type checking
    my $fns = $extracted->{functions} // +{};
    for my $name (keys $fns->%*) {
        my $fn = $extracted->{functions}{$name};
        eval {
            my @param_types;
            for my $expr ($fn->{params_expr}->@*) {
                push @param_types, Typist::Parser->parse($expr);
            }

            my $return_type;
            if ($fn->{returns_expr}) {
                $return_type = Typist::Parser->parse($fn->{returns_expr});
            }

            my $effects;
            if ($fn->{eff_expr}) {
                my $row = Typist::Parser->parse_row($fn->{eff_expr});
                $effects = Typist::Type::Eff->new($row);
            }

            my @generics;
            if ($fn->{generics} && @{$fn->{generics}}) {
                my $spec = join(', ', $fn->{generics}->@*);
                @generics = Typist::Attribute->parse_generic_decl($spec, registry => $reg);
            }

            my $sig = +{
                params   => \@param_types,
                returns  => $return_type,
                generics => \@generics,
                effects  => $effects,
            };

            if ($fn->{is_method}) {
                $reg->register_method($pkg, $name, $sig);
            } else {
                $reg->register_function($pkg, $name, $sig);
            }
        };
        # Skip functions that fail to parse (non-fatal)
    }
}

sub _rebuild_registry ($self) {
    $self->{registry} = Typist::Registry->new;

    # Re-install builtin type prelude (CORE:: defaults)
    Typist::Prelude->install($self->{registry});

    for my $path (sort keys $self->{files}->%*) {
        my $info = $self->{files}{$path};
        # Re-register from stored extracted data (simulate extraction result)
        $self->_register_file_types(+{
            aliases     => $info->{aliases}     // +{},
            functions   => $info->{functions}   // +{},
            newtypes    => $info->{newtypes}    // +{},
            datatypes   => $info->{datatypes}   // +{},
            effects     => $info->{effects}     // +{},
            typeclasses => $info->{typeclasses} // +{},
            declares    => $info->{declares}    // +{},
            package     => $info->{package}     // 'main',
        });
    }
}

# ── Query ────────────────────────────────────────

sub find_definition ($self, $name) {
    for my $path (sort keys $self->{files}->%*) {
        my $info = $self->{files}{$path};

        for my $section (qw(aliases newtypes datatypes effects typeclasses)) {
            my $entries = $info->{$section} // next;
            if (my $entry = $entries->{$name}) {
                return +{
                    uri  => "file://$path",
                    line => ($entry->{line} // 1) - 1,
                    col  => ($entry->{col}  // 1) - 1,
                    name => $name,
                };
            }
        }

        # Functions
        if (my $fn = ($info->{functions} // +{})->{$name}) {
            return +{
                uri  => "file://$path",
                line => ($fn->{line} // 1) - 1,
                col  => ($fn->{col}  // 1) - 1,
                name => $name,
            };
        }

        # Datatype constructor → jump to the owning datatype definition
        for my $dt_name (keys(($info->{datatypes} // +{})->%*)) {
            my $dt = $info->{datatypes}{$dt_name};
            if (exists $dt->{variants}{$name}) {
                return +{
                    uri  => "file://$path",
                    line => ($dt->{line} // 1) - 1,
                    col  => ($dt->{col}  // 1) - 1,
                    name => $name,
                };
            }
        }
    }

    undef;
}

sub all_typedef_names ($self) {
    my %seen;
    for my $info (values $self->{files}->%*) {
        $seen{$_} = 1 for keys($info->{aliases}->%*);
        $seen{$_} = 1 for keys($info->{newtypes}->%*);
        $seen{$_} = 1 for keys(($info->{datatypes} // +{})->%*);
    }
    sort keys %seen;
}

sub all_effect_names ($self) {
    my %seen;
    for my $info (values $self->{files}->%*) {
        $seen{$_} = 1 for keys(($info->{effects} // +{})->%*);
    }
    sort keys %seen;
}

sub all_typeclass_names ($self) {
    my %seen;
    for my $info (values $self->{files}->%*) {
        $seen{$_} = 1 for keys(($info->{typeclasses} // +{})->%*);
    }
    sort keys %seen;
}

sub all_constructor_names ($self) {
    my %seen;
    for my $info (values $self->{files}->%*) {
        for my $dt_info (values(($info->{datatypes} // +{})->%*)) {
            $seen{$_} = 1 for keys($dt_info->{variants}->%*);
        }
    }
    sort keys %seen;
}

1;
