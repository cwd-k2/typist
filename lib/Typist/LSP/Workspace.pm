package Typist::LSP::Workspace;
use v5.40;

use File::Find;
use Typist::Registry;
use Typist::Static::Extractor;
use Typist::Parser;
use Typist::Type::Newtype;
use Typist::Type::Eff;
use Typist::Effect;
use Typist::Attribute;
use Typist::TypeClass;
use Typist::Prelude;

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

    for my $name (keys $extracted->{newtypes}->%*) {
        my $info = $extracted->{newtypes}{$name};
        my $inner = eval { Typist::Parser->parse($info->{inner_expr}) };
        next if $@;
        my $type = Typist::Type::Newtype->new($name, $inner);
        $reg->register_newtype($name, $type);
    }

    for my $name (keys $extracted->{effects}->%*) {
        my $eff = Typist::Effect->new(name => $name, operations => +{});
        $reg->register_effect($name, $eff);
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
    my $pkg = $extracted->{package} // 'main';
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

        for my $section (qw(aliases newtypes effects typeclasses)) {
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
    }

    undef;
}

sub all_typedef_names ($self) {
    my %seen;
    for my $info (values $self->{files}->%*) {
        $seen{$_} = 1 for keys($info->{aliases}->%*);
        $seen{$_} = 1 for keys($info->{newtypes}->%*);
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

1;
