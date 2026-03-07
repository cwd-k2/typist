package Typist::LSP::Workspace;
use v5.40;

our $VERSION = '0.01';

use File::Find;
use Typist::Registry;
use Typist::LSP::Document;
use Typist::Static::Extractor;
use Typist::Static::Registration;
use Typist::Prelude;
use Typist::Subtype;
use JSON::PP ();

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    my $self = bless +{
        root         => $args{root},
        registry     => Typist::Registry->new,
        files        => +{},  # path -> +{ aliases, functions, newtypes, effects, typeclasses, package }
        package_path => +{},  # package -> path
        reverse_deps => +{},  # used package -> { dependent path => 1 }
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

    # Two-pass scan: type definitions first, then function signatures.
    # This ensures cross-file typeclasses are registered before
    # parse_generic_decl classifies constraints (tc vs bound).
    my @all_extracted;
    for my $file (sort @pm_files) {
        my $ext = $self->_extract_file($file) // next;
        push @all_extracted, $ext;
        Typist::Static::Registration->register_types($ext, $self->{registry});
    }
    for my $ext (@all_extracted) {
        Typist::Static::Registration->register_signatures($ext, $self->{registry});
    }
}

# ── File Indexing ────────────────────────────────

sub _extract_file ($self, $path) {
    open my $fh, '<:encoding(UTF-8)', $path or return;
    my $source = do { local $/; <$fh> };
    close $fh;

    my $extracted = eval { Typist::Static::Extractor->extract($source) };
    return if $@;

    $self->_set_file_info($path, $extracted, $self->_build_file_info($extracted, $source));

    $extracted;
}

sub _index_file ($self, $path) {
    my $extracted = $self->_extract_file($path) // return;
    $self->_register_file_types($extracted);
}

# ── Incremental Update ──────────────────────────

sub update_file ($self, $path, $source) {
    my $old_info = $self->{files}{$path};

    my $extracted = eval { Typist::Static::Extractor->extract($source) };
    if ($@) {
        # Parse error — conservatively report exports changed
        return (undef, 1);
    }

    my $new_fingerprint = $self->_compute_fingerprint($extracted);
    my $old_fingerprint = $old_info && $old_info->{fingerprint};
    my $exports_changed = !defined $old_fingerprint
                       || $old_fingerprint ne $new_fingerprint;

    my $new_info = $self->_build_file_info($extracted, $source);
    my @affected_paths = $exports_changed
        ? $self->_affected_paths_for_export_change($path, $old_info, $new_info)
        : ($path);

    # Differential update: unregister old, register new
    if ($old_info) {
        $self->_unregister_file_types($old_info);
    }

    $self->_set_file_info($path, $extracted, $new_info);

    $self->_register_file_types($extracted);

    ($extracted, $exports_changed, \@affected_paths);
}

sub _unregister_file_types ($self, $old_info) {
    my $reg = $self->{registry};
    my $pkg = $old_info->{package} // 'main';

    # Unregister functions
    for my $name (keys(($old_info->{functions} // +{})->%*)) {
        my $fn = $old_info->{functions}{$name};
        if ($fn->{is_method}) {
            # Methods are in the method store — skip for now (method unregister not yet needed)
        } else {
            $reg->unregister_function($pkg, $name);
        }
    }

    # Unregister newtype constructors + coerce
    for my $name (keys(($old_info->{newtypes} // +{})->%*)) {
        $reg->unregister_function($pkg, $name);
        $reg->unregister_function($name, 'coerce');
    }

    # Unregister datatype constructors
    for my $dt_name (keys(($old_info->{datatypes} // +{})->%*)) {
        my $dt = $old_info->{datatypes}{$dt_name};
        for my $tag (keys(($dt->{variants} // +{})->%*)) {
            $reg->unregister_function($pkg, $tag);
        }
    }

    # Unregister struct constructors + derive
    for my $name (keys(($old_info->{structs} // +{})->%*)) {
        $reg->unregister_function($pkg, $name);
        $reg->unregister_function($name, 'derive');
    }

    # Unregister effect operations
    for my $eff_name (keys(($old_info->{effects} // +{})->%*)) {
        my $eff = $old_info->{effects}{$eff_name};
        for my $op_name (keys(($eff->{operations} // +{})->%*)) {
            $reg->unregister_function($eff_name, $op_name);
        }
    }

    # Unregister typeclass methods
    for my $tc_name (keys(($old_info->{typeclasses} // +{})->%*)) {
        my $tc = $old_info->{typeclasses}{$tc_name};
        for my $method_name (keys(($tc->{methods} // +{})->%*)) {
            $reg->unregister_function($tc_name, $method_name);
        }
    }

    # Unregister instances
    for my $inst_info (($old_info->{instances} // [])->@*) {
        $reg->unregister_instance($inst_info->{class_name}, $inst_info->{type_expr});
    }

    # Unregister declare entries
    for my $name (keys(($old_info->{declares} // +{})->%*)) {
        my $decl = $old_info->{declares}{$name};
        $reg->unregister_function($decl->{package}, $decl->{func_name});
    }

    # ── Unregister type objects (prevent ghosts) ──

    # Aliases
    for my $name (keys(($old_info->{aliases} // +{})->%*)) {
        $reg->unregister_alias($name);
    }

    # Newtypes (type object)
    for my $name (keys(($old_info->{newtypes} // +{})->%*)) {
        $reg->unregister_newtype($name);
    }

    # Datatypes (type object)
    for my $name (keys(($old_info->{datatypes} // +{})->%*)) {
        $reg->unregister_datatype($name);
    }

    # Structs (type object + accessor methods)
    for my $name (keys(($old_info->{structs} // +{})->%*)) {
        $reg->unregister_type($name);
        my $spkg = "Typist::Struct::${name}";
        for my $f (keys(($old_info->{structs}{$name}{fields} // +{})->%*)) {
            $reg->unregister_method($spkg, $f);
        }
    }

    # Effects (type object)
    for my $name (keys(($old_info->{effects} // +{})->%*)) {
        $reg->unregister_effect($name);
    }

    # Typeclasses (type object)
    for my $name (keys(($old_info->{typeclasses} // +{})->%*)) {
        $reg->unregister_typeclass($name);
    }

    # Clear resolved cache since aliases/types may have changed
    $reg->{resolved} = +{};

    # Clear subtype cache — type definitions may have changed
    Typist::Subtype->clear_cache;
}

sub _register_file_types ($self, $extracted) {
    Typist::Static::Registration->register_all($extracted, $self->{registry});
}

sub _rebuild_registry ($self) {
    $self->{registry} = Typist::Registry->new;
    $self->{package_path} = +{};
    $self->{reverse_deps} = +{};

    # Re-install builtin type prelude (CORE:: defaults)
    Typist::Prelude->install($self->{registry});

    # Two-pass rebuild: types first, signatures second
    my @all_extracted;
    for my $path (sort keys $self->{files}->%*) {
        my $info = $self->{files}{$path};
        my $ext = +{
            aliases     => $info->{aliases}     // +{},
            functions   => $info->{functions}   // +{},
            newtypes    => $info->{newtypes}    // +{},
            datatypes   => $info->{datatypes}   // +{},
            structs     => $info->{structs}     // +{},
            effects     => $info->{effects}     // +{},
            typeclasses => $info->{typeclasses} // +{},
            instances   => $info->{instances}   // [],
            declares    => $info->{declares}    // +{},
            use_modules => $info->{use_modules} // [],
            package     => $info->{package}     // 'main',
        };
        $self->_refresh_dependency_index($path, undef, $info);
        Typist::Static::Registration->register_types($ext, $self->{registry});
        push @all_extracted, $ext;
    }
    for my $ext (@all_extracted) {
        Typist::Static::Registration->register_signatures($ext, $self->{registry});
    }
}

sub _build_file_info ($self, $extracted, $source = '') {
    +{
        aliases     => $extracted->{aliases},
        functions   => $extracted->{functions},
        newtypes    => $extracted->{newtypes},
        datatypes   => $extracted->{datatypes},
        structs     => $extracted->{structs},
        effects     => $extracted->{effects},
        typeclasses => $extracted->{typeclasses},
        instances   => $extracted->{instances},
        declares    => $extracted->{declares},
        use_modules => [@{$extracted->{use_modules} // []}],
        package     => $extracted->{package},
        fingerprint => $self->_compute_fingerprint($extracted),
        occurrences => _build_occurrence_index($source),
    };
}

sub _set_file_info ($self, $path, $extracted, $info = undef) {
    my $old_info = $self->{files}{$path};
    my $new_info = $info // $self->_build_file_info($extracted);
    $self->{files}{$path} = $new_info;
    $self->_refresh_dependency_index($path, $old_info, $new_info);
    $new_info;
}

sub _refresh_dependency_index ($self, $path, $old_info, $new_info) {
    if ($old_info) {
        my $old_pkg = $old_info->{package};
        if (defined $old_pkg && ($self->{package_path}{$old_pkg} // '') eq $path) {
            delete $self->{package_path}{$old_pkg};
        }
        for my $used (@{$old_info->{use_modules} // []}) {
            my $deps = $self->{reverse_deps}{$used} // next;
            delete $deps->{$path};
            delete $self->{reverse_deps}{$used} unless %$deps;
        }
    }

    return unless $new_info;

    my $pkg = $new_info->{package} // 'main';
    $self->{package_path}{$pkg} = $path;
    for my $used (@{$new_info->{use_modules} // []}) {
        $self->{reverse_deps}{$used}{$path} = 1;
    }
}

sub _affected_paths_for_export_change ($self, $path, $old_info, $new_info) {
    my %affected = ($path => 1);
    my %seen_pkg;
    my @queue = grep {
        defined $_ && length $_ && !$seen_pkg{$_}++
    } (
        $old_info ? ($old_info->{package}) : (),
        $new_info ? ($new_info->{package}) : (),
    );

    while (@queue) {
        my $pkg = shift @queue;
        for my $dep_path (keys(($self->{reverse_deps}{$pkg} // +{})->%*)) {
            next if $affected{$dep_path}++;
            my $dep_pkg = $self->{files}{$dep_path}{package};
            next unless defined $dep_pkg && length $dep_pkg;
            next if $seen_pkg{$dep_pkg}++;
            push @queue, $dep_pkg;
        }
    }

    sort keys %affected;
}

# ── Export Fingerprint ──────────────────────────

# Extract the "export surface" — fields that affect Registry registration.
# Excludes: line, col, end_line, block, param_names, default_count,
# method_kind, name_col, op_names (display-only / analysis-internal).
sub _export_surface ($extracted) {
    my %surface = (package => $extracted->{package} // 'main');

    # Aliases: name => expr (string, no position info)
    $surface{aliases} = $extracted->{aliases} if %{$extracted->{aliases} // +{}};

    # Functions: only annotated ones affect Registry signatures
    my %fns;
    for my $name (sort keys %{$extracted->{functions} // +{}}) {
        my $fn = $extracted->{functions}{$name};
        next if $fn->{unannotated};
        $fns{$name} = +{
            params_expr  => $fn->{params_expr},
            returns_expr => $fn->{returns_expr},
            generics     => $fn->{generics},
            eff_expr     => $fn->{eff_expr},
            variadic     => $fn->{variadic},
            is_method    => $fn->{is_method},
        };
    }
    $surface{functions} = \%fns if %fns;

    # Newtypes: name => inner_expr
    $surface{newtypes} = $extracted->{newtypes}
        if %{$extracted->{newtypes} // +{}};

    # Datatypes: name => { variants, type_params }
    if (%{$extracted->{datatypes} // +{}}) {
        my %dts;
        for my $name (keys %{$extracted->{datatypes}}) {
            my $dt = $extracted->{datatypes}{$name};
            $dts{$name} = +{
                variants    => $dt->{variants},
                type_params => $dt->{type_params},
            };
        }
        $surface{datatypes} = \%dts;
    }

    # Structs: name => { fields, optional_fields, type_params, type_param_specs }
    if (%{$extracted->{structs} // +{}}) {
        my %sts;
        for my $name (keys %{$extracted->{structs}}) {
            my $st = $extracted->{structs}{$name};
            $sts{$name} = +{
                fields           => $st->{fields},
                optional_fields  => $st->{optional_fields},
                type_params      => $st->{type_params},
                type_param_specs => $st->{type_param_specs},
            };
        }
        $surface{structs} = \%sts;
    }

    # Effects: name => { operations, protocol, states, op_map }
    if (%{$extracted->{effects} // +{}}) {
        my %effs;
        for my $name (keys %{$extracted->{effects}}) {
            my $eff = $extracted->{effects}{$name};
            $effs{$name} = +{
                operations => $eff->{operations},
                protocol   => $eff->{protocol},
                states     => $eff->{states},
                op_map     => $eff->{op_map},
            };
        }
        $surface{effects} = \%effs;
    }

    # Typeclasses: name => { var_spec, methods }
    if (%{$extracted->{typeclasses} // +{}}) {
        my %tcs;
        for my $name (keys %{$extracted->{typeclasses}}) {
            my $tc = $extracted->{typeclasses}{$name};
            $tcs{$name} = +{
                var_spec => $tc->{var_spec},
                methods  => $tc->{methods},
            };
        }
        $surface{typeclasses} = \%tcs;
    }

    # Instances: sorted by class_name + type_expr
    if (@{$extracted->{instances} // []}) {
        $surface{instances} = [
            map  { +{ class_name => $_->{class_name}, type_expr => $_->{type_expr} } }
            sort { ($a->{class_name} cmp $b->{class_name}) || ($a->{type_expr} cmp $b->{type_expr}) }
            @{$extracted->{instances}}
        ];
    }

    # Declares: name => type_expr
    if (%{$extracted->{declares} // +{}}) {
        my %decls;
        for my $name (keys %{$extracted->{declares}}) {
            $decls{$name} = $extracted->{declares}{$name}{type_expr};
        }
        $surface{declares} = \%decls;
    }

    \%surface;
}

my $_json_encoder = JSON::PP->new->utf8->canonical;

sub _compute_fingerprint ($self, $extracted) {
    $_json_encoder->encode(_export_surface($extracted));
}

sub _build_occurrence_index ($source) {
    my %index;
    my @lines = split /\n/, ($source // ''), -1;

    for my $line_no (0 .. $#lines) {
        my $text = $lines[$line_no];
        while ($text =~ /(?<![A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])/g) {
            my $word = $1;
            push @{$index{$word} //= []}, +{
                line => $line_no,
                col  => $-[1],
                len  => length($word),
            };
        }
    }

    \%index;
}

# ── Query ────────────────────────────────────────

sub find_definition ($self, $name) {
    for my $path (sort keys $self->{files}->%*) {
        my $info = $self->{files}{$path};

        for my $section (qw(aliases newtypes datatypes structs effects typeclasses)) {
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
        $seen{$_} = 1 for keys(($info->{structs} // +{})->%*);
    }
    sort keys %seen;
}

sub all_effect_names ($self) {
    my %seen;
    for my $info (values $self->{files}->%*) {
        $seen{$_} = 1 for keys(($info->{effects} // +{})->%*);
    }
    # Include registry effects (Prelude: IO, Exn, Decl + merged workspace effects)
    my %reg_effects = $self->{registry}->all_effects;
    $seen{$_} = 1 for keys %reg_effects;
    sort keys %seen;
}

sub all_typeclass_names ($self) {
    my %seen;
    for my $info (values $self->{files}->%*) {
        $seen{$_} = 1 for keys(($info->{typeclasses} // +{})->%*);
    }
    sort keys %seen;
}

# ── Find References ──────────────────────────────

# Find all word-boundary occurrences of $name across open documents and workspace files.
# $open_documents: hashref of uri => Document (already searched in-memory).
sub find_all_references ($self, $name, $open_documents = +{}) {
    my @all_refs;

    # Search in open documents (they have up-to-date content in memory)
    for my $uri (sort keys %$open_documents) {
        my $doc = $open_documents->{$uri};
        push @all_refs, @{$doc->find_references($name)};
    }

    # Search in workspace files not currently open
    for my $path (sort keys $self->{files}->%*) {
        my $uri = "file://$path";
        next if $open_documents->{$uri};  # already searched above

        my $hits = ($self->{files}{$path}{occurrences} // +{})->{$name} // [];
        push @all_refs, map { +{ %$_, uri => $uri } } @$hits;
    }

    \@all_refs;
}

# ── Query (names) ────────────────────────────────

sub all_constructor_names ($self) {
    my %seen;
    for my $info (values $self->{files}->%*) {
        for my $dt_info (values(($info->{datatypes} // +{})->%*)) {
            $seen{$_} = 1 for keys($dt_info->{variants}->%*);
        }
        # Include struct names (constructor = struct name)
        $seen{$_} = 1 for keys(($info->{structs} // +{})->%*);
        # Include newtype names (constructor = newtype name)
        $seen{$_} = 1 for keys(($info->{newtypes} // +{})->%*);
    }
    sort keys %seen;
}

1;

__END__

=head1 NAME

Typist::LSP::Workspace - Cross-file type registry and workspace management

=head1 SYNOPSIS

    use Typist::LSP::Workspace;

    my $ws = Typist::LSP::Workspace->new(root => '/path/to/lib');

    my $registry = $ws->registry;
    $ws->update_file($path, $source);

    my $def = $ws->find_definition('MyType');
    my @names = $ws->all_typedef_names;

=head1 DESCRIPTION

Typist::LSP::Workspace scans a project directory for C<.pm> files,
extracts type definitions using L<Typist::Static::Extractor>, and
maintains a shared L<Typist::Registry> for cross-file type resolution.
It also supports incremental updates when files are saved.

The workspace registry includes builtin function types from
L<Typist::Prelude> and registers all discovered aliases, newtypes,
datatypes, effects, typeclasses, and function signatures.

=head1 CONSTRUCTOR

=head2 new

    my $ws = Typist::LSP::Workspace->new(root => $lib_dir);

Create a workspace rooted at the given directory. If C<root> is provided
and is a valid directory, the workspace scans it immediately for C<.pm>
files and populates the registry.

=head1 METHODS

=head2 registry

    my $reg = $ws->registry;

Returns the shared L<Typist::Registry> containing all workspace-level
type definitions and function signatures.

=head2 scan

    $ws->scan;

Recursively scan the workspace root for C<.pm> files and index their
type definitions. Called automatically by the constructor when a root
directory is provided.

=head2 update_file

    $ws->update_file($path, $source);

Incrementally update the workspace index for a single file. Removes
the old entry, rebuilds the registry, and re-indexes the file with
the new source content.

=head2 find_definition

    my $def = $ws->find_definition($name);

Search the workspace for the definition of a named symbol (alias,
newtype, datatype, effect, typeclass, function, or datatype constructor).
Returns C<< +{ uri, line, col, name } >> or C<undef>.

=head2 find_all_references

    my $refs = $ws->find_all_references($name, \%open_documents);

Find all word-boundary occurrences of C<$name> across open documents
and workspace files. Returns an arrayref of C<< +{ uri, line, col, len } >>.

=head2 all_typedef_names

    my @names = $ws->all_typedef_names;

Returns a sorted list of all alias, newtype, and datatype names.

=head2 all_effect_names

    my @names = $ws->all_effect_names;

Returns a sorted list of all effect names.

=head2 all_typeclass_names

    my @names = $ws->all_typeclass_names;

Returns a sorted list of all typeclass names.

=head2 all_constructor_names

    my @names = $ws->all_constructor_names;

Returns a sorted list of all datatype constructor (variant) names.

=head1 SEE ALSO

L<Typist::LSP::Server>, L<Typist::Registry>, L<Typist::Static::Extractor>

=cut
