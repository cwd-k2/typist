package Typist::LSP::Workspace;
use v5.40;

our $VERSION = '0.01';

use File::Find;
use Typist::Registry;
use Typist::LSP::Document;
use Typist::Static::Extractor;
use Typist::Static::Registration;
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
        datatypes   => $extracted->{datatypes},
        structs     => $extracted->{structs},
        effects     => $extracted->{effects},
        typeclasses => $extracted->{typeclasses},
        declares    => $extracted->{declares},
        package     => $extracted->{package},
    };

    $self->_register_file_types($extracted);
}

# ── Incremental Update ──────────────────────────

sub update_file ($self, $path, $source) {
    my $old_info = $self->{files}{$path};

    my $extracted = eval { Typist::Static::Extractor->extract($source) };
    return if $@;

    # Differential update: unregister old, register new
    if ($old_info) {
        $self->_unregister_file_types($old_info);
    }

    $self->{files}{$path} = +{
        aliases     => $extracted->{aliases},
        functions   => $extracted->{functions},
        newtypes    => $extracted->{newtypes},
        datatypes   => $extracted->{datatypes},
        structs     => $extracted->{structs},
        effects     => $extracted->{effects},
        typeclasses => $extracted->{typeclasses},
        declares    => $extracted->{declares},
        package     => $extracted->{package},
    };

    $self->_register_file_types($extracted);
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

    # Unregister newtype constructors
    for my $name (keys(($old_info->{newtypes} // +{})->%*)) {
        $reg->unregister_function($pkg, $name);
    }

    # Unregister datatype constructors
    for my $dt_name (keys(($old_info->{datatypes} // +{})->%*)) {
        my $dt = $old_info->{datatypes}{$dt_name};
        for my $tag (keys(($dt->{variants} // +{})->%*)) {
            $reg->unregister_function($pkg, $tag);
        }
    }

    # Unregister struct constructors
    for my $name (keys(($old_info->{structs} // +{})->%*)) {
        $reg->unregister_function($pkg, $name);
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

    # Unregister declare entries
    for my $name (keys(($old_info->{declares} // +{})->%*)) {
        my $decl = $old_info->{declares}{$name};
        $reg->unregister_function($decl->{package}, $decl->{func_name});
    }

    # Clear resolved cache since aliases/types may have changed
    $reg->{resolved} = +{};
}

sub _register_file_types ($self, $extracted) {
    Typist::Static::Registration->register_all($extracted, $self->{registry});
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
            structs     => $info->{structs}     // +{},
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

        my $content = eval { _read_file($path) } // next;
        my @lines = split /\n/, $content, -1;
        my $hits = Typist::LSP::Document->_find_word_occurrences(\@lines, $name);
        push @all_refs, map { +{ %$_, uri => $uri } } @$hits;
    }

    \@all_refs;
}

sub _read_file ($path) {
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read $path: $!";
    local $/;
    <$fh>;
}

# ── Query (names) ────────────────────────────────

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
