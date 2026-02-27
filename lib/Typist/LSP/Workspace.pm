package Typist::LSP::Workspace;
use v5.40;

use File::Find;
use Typist::Registry;
use Typist::Static::Extractor;
use Typist::Parser;
use Typist::Type::Newtype;
use Typist::Effect;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    my $self = bless +{
        root     => $args{root},
        registry => Typist::Registry->new,
        files    => +{},  # path -> +{ aliases, functions, newtypes, effects, typeclasses, package }
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
}

sub _rebuild_registry ($self) {
    $self->{registry} = Typist::Registry->new;

    for my $path (sort keys $self->{files}->%*) {
        my $info = $self->{files}{$path};
        # Re-register from stored extracted data (simulate extraction result)
        $self->_register_file_types(+{
            aliases     => $info->{aliases}     // +{},
            newtypes    => $info->{newtypes}    // +{},
            effects     => $info->{effects}     // +{},
            typeclasses => $info->{typeclasses} // +{},
        });
    }
}

# ── Query ────────────────────────────────────────

sub all_typedef_names ($self) {
    my %seen;
    for my $info (values $self->{files}->%*) {
        $seen{$_} = 1 for keys($info->{aliases}->%*);
        $seen{$_} = 1 for keys($info->{newtypes}->%*);
    }
    sort keys %seen;
}

1;
