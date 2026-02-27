package Typist::LSP::Workspace;
use v5.40;

use File::Find;
use Typist::Registry;
use Typist::Static::Extractor;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    my $self = bless {
        root     => $args{root},
        registry => Typist::Registry->new,
        files    => {},  # path -> { aliases => {...} }
    }, $class;

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
    open my $fh, '<', $path or return;
    my $source = do { local $/; <$fh> };
    close $fh;

    my $extracted = eval { Typist::Static::Extractor->extract($source) };
    return if $@;

    # Store file's contribution
    $self->{files}{$path} = {
        aliases   => $extracted->{aliases},
        functions => $extracted->{functions},
        package   => $extracted->{package},
    };

    # Register aliases into workspace registry
    for my $name (keys $extracted->{aliases}->%*) {
        $self->{registry}->define_alias($name, $extracted->{aliases}{$name}{expr});
    }
}

# ── Incremental Update ──────────────────────────

sub update_file ($self, $path, $source) {
    # Remove old contributions from this file
    if (my $old = $self->{files}{$path}) {
        # We need to rebuild the registry from remaining files
        delete $self->{files}{$path};
        $self->_rebuild_registry;
    }

    # Re-extract and register
    my $extracted = eval { Typist::Static::Extractor->extract($source) };
    return if $@;

    $self->{files}{$path} = {
        aliases   => $extracted->{aliases},
        functions => $extracted->{functions},
        package   => $extracted->{package},
    };

    for my $name (keys $extracted->{aliases}->%*) {
        $self->{registry}->define_alias($name, $extracted->{aliases}{$name}{expr});
    }
}

sub _rebuild_registry ($self) {
    $self->{registry} = Typist::Registry->new;

    for my $path (sort keys $self->{files}->%*) {
        my $info = $self->{files}{$path};
        for my $name (keys $info->{aliases}->%*) {
            $self->{registry}->define_alias($name, $info->{aliases}{$name}{expr});
        }
    }
}

# ── Query ────────────────────────────────────────

# Return all known typedef names across the workspace.
sub all_typedef_names ($self) {
    my %seen;
    for my $info (values $self->{files}->%*) {
        $seen{$_} = 1 for keys $info->{aliases}->%*;
    }
    sort keys %seen;
}

1;
