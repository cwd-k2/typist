package Typist::LSP::Server;
use v5.40;

use Typist::LSP::Transport;
use Typist::LSP::Document;
use Typist::LSP::Workspace;
use Typist::LSP::Hover;
use Typist::LSP::Completion;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless {
        transport => $args{transport} // Typist::LSP::Transport->new,
        workspace => undef,
        documents => {},
        shutdown  => 0,
        exit      => 0,
    }, $class;
}

# ── Main Loop ────────────────────────────────────

sub run ($self) {
    while (my $msg = $self->{transport}->read_message) {
        if (my $method = $msg->{method}) {
            my $id     = $msg->{id};
            my $params = $msg->{params} // {};

            my $handler = $self->_dispatch($method);

            if ($handler) {
                my $result = eval { $handler->($self, $params) };
                if ($@) {
                    $self->{transport}->send_error($id, -32603, "$@") if defined $id;
                } elsif (defined $id) {
                    $self->{transport}->send_response($id, $result);
                }
            } elsif (defined $id) {
                $self->{transport}->send_error($id, -32601, "Method not found: $method");
            }
        }

        last if $self->{exit};
    }
}

# ── Dispatch Table ───────────────────────────────

sub _dispatch ($self, $method) {
    my %table = (
        'initialize'              => \&_handle_initialize,
        'initialized'             => \&_handle_noop,
        'shutdown'                => \&_handle_shutdown,
        'exit'                    => \&_handle_exit,
        'textDocument/didOpen'    => \&_handle_did_open,
        'textDocument/didChange'  => \&_handle_did_change,
        'textDocument/didSave'    => \&_handle_did_save,
        'textDocument/didClose'   => \&_handle_did_close,
        'textDocument/hover'      => \&_handle_hover,
        'textDocument/completion' => \&_handle_completion,
    );

    $table{$method};
}

# ── Lifecycle Handlers ──────────────────────────

sub _handle_initialize ($self, $params) {
    # Initialize workspace from root URI
    my $root = $params->{rootUri} // $params->{rootPath};
    if ($root) {
        $root =~ s{^file://}{};
        my $lib = "$root/lib";
        $self->{workspace} = Typist::LSP::Workspace->new(root => -d $lib ? $lib : $root);
    } else {
        $self->{workspace} = Typist::LSP::Workspace->new;
    }

    {
        capabilities => {
            textDocumentSync => {
                openClose => \1,
                change    => 1,  # Full content sync
                save      => { includeText => \1 },
            },
            hoverProvider      => \1,
            completionProvider => {
                triggerCharacters => ['(', '[', ',', '|', '&'],
            },
        },
    };
}

sub _handle_shutdown ($self, $params) {
    $self->{shutdown} = 1;
    undef;
}

sub _handle_exit ($self, $params) {
    $self->{exit} = 1;
    undef;
}

sub _handle_noop ($self, $params) { undef }

# ── Document Handlers ───────────────────────────

sub _handle_did_open ($self, $params) {
    my $td  = $params->{textDocument};
    my $uri = $td->{uri};

    my $doc = Typist::LSP::Document->new(
        uri     => $uri,
        content => $td->{text},
        version => $td->{version},
    );

    $self->{documents}{$uri} = $doc;
    $self->_publish_diagnostics($doc);

    undef;
}

sub _handle_did_change ($self, $params) {
    my $uri     = $params->{textDocument}{uri};
    my $doc     = $self->{documents}{$uri} // return undef;
    my $changes = $params->{contentChanges} // [];

    # Full sync — take the last change
    if (@$changes) {
        $doc->update($changes->[-1]{text}, $params->{textDocument}{version});
    }

    $self->_publish_diagnostics($doc);

    undef;
}

sub _handle_did_save ($self, $params) {
    my $uri = $params->{textDocument}{uri};
    my $doc = $self->{documents}{$uri} // return undef;

    # Update content if provided
    if (my $text = $params->{text}) {
        $doc->update($text, $doc->version);
    }

    # Update workspace index
    my $path = $uri =~ s{^file://}{}r;
    $self->{workspace}->update_file($path, $doc->content) if $self->{workspace};

    $self->_publish_diagnostics($doc);

    undef;
}

sub _handle_did_close ($self, $params) {
    delete $self->{documents}{$params->{textDocument}{uri}};
    undef;
}

# ── Hover Handler ────────────────────────────────

sub _handle_hover ($self, $params) {
    my $uri  = $params->{textDocument}{uri};
    my $doc  = $self->{documents}{$uri} // return undef;
    my $pos  = $params->{position};
    my $line = $pos->{line};
    my $col  = $pos->{character};

    # Ensure document is analyzed
    $doc->analyze(workspace_registry => $self->{workspace} && $self->{workspace}->registry);

    my $sym = $doc->symbol_at($line, $col);
    Typist::LSP::Hover->hover($sym);
}

# ── Completion Handler ──────────────────────────

sub _handle_completion ($self, $params) {
    my $uri = $params->{textDocument}{uri};
    my $doc = $self->{documents}{$uri} // return { items => [] };
    my $pos = $params->{position};

    my $ctx = $doc->completion_context($pos->{line}, $pos->{character});
    return { items => [] } unless $ctx;

    my @typedefs = $self->{workspace} ? $self->{workspace}->all_typedef_names : ();
    my $items = Typist::LSP::Completion->complete($ctx, \@typedefs);

    { items => $items };
}

# ── Diagnostics Publishing ──────────────────────

sub _publish_diagnostics ($self, $doc) {
    my $result = $doc->analyze(
        workspace_registry => $self->{workspace} && $self->{workspace}->registry,
    );

    my @lsp_diags;
    for my $d ($result->{diagnostics}->@*) {
        my $line = ($d->{line} // 1) - 1;  # Convert to 0-indexed
        $line = 0 if $line < 0;

        push @lsp_diags, {
            range => {
                start => { line => $line, character => 0 },
                end   => { line => $line, character => 999 },
            },
            severity => _lsp_severity($d->{severity}),
            source   => 'typist',
            message  => $d->{message},
        };
    }

    $self->{transport}->send_notification('textDocument/publishDiagnostics', {
        uri         => $doc->uri,
        diagnostics => \@lsp_diags,
    });
}

# Map internal severity (1=critical..4=info) to LSP severity (1=Error..4=Hint)
sub _lsp_severity ($internal) {
    $internal // 3;
}

1;
