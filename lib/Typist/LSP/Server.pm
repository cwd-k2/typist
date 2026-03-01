package Typist::LSP::Server;
use v5.40;

our $VERSION = '0.01';

use Typist::LSP::Transport;
use Typist::LSP::Document;
use Typist::LSP::Workspace;
use Typist::LSP::Hover;
use Typist::LSP::Completion;
use Typist::LSP::SemanticTokens;
use Typist::LSP::Logger;

# ── Dispatch Table (class-level constant) ──────

my %DISPATCH = (
    'initialize'              => \&_handle_initialize,
    'initialized'             => \&_handle_noop,
    'shutdown'                => \&_handle_shutdown,
    'exit'                    => \&_handle_exit,
    'textDocument/didOpen'    => \&_handle_did_open,
    'textDocument/didChange'  => \&_handle_did_change,
    'textDocument/didSave'    => \&_handle_did_save,
    'textDocument/didClose'   => \&_handle_did_close,
    'textDocument/hover'          => \&_handle_hover,
    'textDocument/completion'     => \&_handle_completion,
    'textDocument/documentSymbol' => \&_handle_document_symbol,
    'textDocument/definition'     => \&_handle_definition,
    'textDocument/signatureHelp'  => \&_handle_signature_help,
    'textDocument/inlayHint'              => \&_handle_inlay_hint,
    'textDocument/references'             => \&_handle_references,
    'textDocument/rename'                 => \&_handle_rename,
    'textDocument/semanticTokens/full'    => \&_handle_semantic_tokens,
);

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        transport => $args{transport} // Typist::LSP::Transport->new,
        log       => $args{logger}    // Typist::LSP::Logger->new,
        workspace => undef,
        documents => +{},
        shutdown  => 0,
        exit      => 0,
    }, $class;
}

# ── Main Loop ────────────────────────────────────

sub run ($self) {
    my $log = $self->{log};
    $log->info('typist-lsp starting');

    # Ignore SIGPIPE — client may disconnect at any time
    local $SIG{PIPE} = 'IGNORE';

    while (my $msg = $self->{transport}->read_message) {
        my $method = $msg->{method} // next;
        my $id     = $msg->{id};
        my $params = $msg->{params} // +{};

        $log->debug("recv $method" . (defined $id ? " (id=$id)" : ''));

        # After shutdown, reject all requests except exit
        if ($self->{shutdown} && $method ne 'exit') {
            if (defined $id) {
                $self->{transport}->send_error($id, -32600, 'Server is shutting down');
            }
            next;
        }

        my $handler = $DISPATCH{$method};

        if ($handler) {
            my $result = eval { $handler->($self, $params) };
            if ($@) {
                my $err = "$@";
                chomp $err;
                $log->error("handler $method died: $err");
                $self->{transport}->send_error($id, -32603, $err) if defined $id;
            } elsif (defined $id) {
                $self->{transport}->send_response($id, $result);
            }
        } elsif (defined $id) {
            $log->warn("unknown method: $method");
            $self->{transport}->send_error($id, -32601, "Method not found: $method");
        }

        last if $self->{exit};
    }

    $log->info('typist-lsp exiting');
}

# ── Lifecycle Handlers ──────────────────────────

sub _handle_initialize ($self, $params) {
    my $root = $params->{rootUri} // $params->{rootPath};
    if ($root) {
        $root = _uri_to_path($root);
        my $lib = "$root/lib";
        $self->{workspace} = Typist::LSP::Workspace->new(root => -d $lib ? $lib : $root);
        $self->{log}->info("workspace root: $root");
    } else {
        $self->{workspace} = Typist::LSP::Workspace->new;
        $self->{log}->info('workspace: no root');
    }

    +{
        capabilities => +{
            textDocumentSync => +{
                openClose => \1,
                change    => 1,  # Full content sync
                save      => +{ includeText => \1 },
            },
            hoverProvider          => \1,
            documentSymbolProvider => \1,
            definitionProvider     => \1,
            signatureHelpProvider  => +{
                triggerCharacters => ['(', ','],
            },
            referencesProvider     => \1,
            renameProvider         => \1,
            inlayHintProvider      => \1,
            completionProvider => +{
                triggerCharacters => ['(', '[', ',', '|', '&', '>', '{', ':'],
            },
            semanticTokensProvider => +{
                legend => Typist::LSP::SemanticTokens->legend,
                full   => \1,
            },
        },
        serverInfo => +{
            name    => 'typist-lsp',
            version => '0.1.0',
        },
    };
}

sub _handle_shutdown ($self, $params) {
    $self->{shutdown} = 1;
    $self->{log}->info('shutdown requested');
    undef;
}

sub _handle_exit ($self, $params) {
    $self->{exit} = 1;
    undef;
}

sub _handle_noop ($self, $params) { undef }

sub did_shutdown ($self) { $self->{shutdown} }

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
    $self->{log}->debug("didOpen $uri (v$td->{version})");
    $self->_publish_diagnostics($doc);

    undef;
}

sub _handle_did_change ($self, $params) {
    my $uri     = $params->{textDocument}{uri};
    my $doc     = $self->{documents}{$uri} // return undef;
    my $changes = $params->{contentChanges} // [];

    # Full sync — take the last change
    if (@$changes) {
        my $ver = $params->{textDocument}{version};
        $doc->update($changes->[-1]{text}, $ver);
        $self->{log}->debug("didChange $uri (v$ver)");
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
    my $path = _uri_to_path($uri);
    $self->{workspace}->update_file($path, $doc->content) if $self->{workspace};
    $self->{log}->debug("didSave $uri -> workspace updated");

    # Invalidate and re-diagnose all open documents (cross-file types may have changed)
    for my $other_doc (values $self->{documents}->%*) {
        $other_doc->invalidate;
        $self->_publish_diagnostics($other_doc);
    }

    undef;
}

sub _handle_did_close ($self, $params) {
    my $uri = $params->{textDocument}{uri};
    delete $self->{documents}{$uri};
    $self->{log}->debug("didClose $uri");
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
    my $doc = $self->{documents}{$uri} // return +{ items => [] };
    my $pos = $params->{position};
    my $line = $pos->{line};
    my $col  = $pos->{character};

    # Type annotation context (existing)
    if (my $ctx = $doc->completion_context($line, $col)) {
        my @typedefs    = $self->{workspace} ? $self->{workspace}->all_typedef_names    : ();
        my @effects     = $self->{workspace} ? $self->{workspace}->all_effect_names     : ();
        my @typeclasses = $self->{workspace} ? $self->{workspace}->all_typeclass_names  : ();
        my $items = Typist::LSP::Completion->complete($ctx, \@typedefs, \@effects, \@typeclasses);
        return +{ items => $items };
    }

    # Code completion context (type-aware)
    if (my $code_ctx = $doc->code_completion_at($line, $col)) {
        $doc->analyze(workspace_registry => $self->{workspace} && $self->{workspace}->registry)
            unless $doc->{result};
        my $registry = $self->{workspace} ? $self->{workspace}->registry : undef;
        my $items = Typist::LSP::Completion->complete_code($code_ctx, $doc, $registry);
        return +{ isIncomplete => \0, items => $items } if @$items;
    }

    # Fallback: constructor completions
    my @constructors = $self->{workspace} ? $self->{workspace}->all_constructor_names : ();
    return +{ items => [] } unless @constructors;
    my @items = map { +{
        label  => $_,
        kind   => 3,  # Function
        detail => 'constructor',
    } } @constructors;
    +{ items => \@items };
}

# ── Inlay Hint Handler ──────────────────────────

sub _handle_inlay_hint ($self, $params) {
    my $uri   = $params->{textDocument}{uri};
    my $doc   = $self->{documents}{$uri} // return [];
    my $range = $params->{range};

    $doc->analyze(workspace_registry => $self->{workspace} && $self->{workspace}->registry);

    my $start = $range->{start}{line};
    my $end   = $range->{end}{line};

    $doc->inlay_hints($start, $end);
}

# ── Semantic Tokens Handler ────────────────────

sub _handle_semantic_tokens ($self, $params) {
    my $uri = $params->{textDocument}{uri};
    my $doc = $self->{documents}{$uri} // return +{ data => [] };

    $doc->analyze(workspace_registry => $self->{workspace} && $self->{workspace}->registry);

    Typist::LSP::SemanticTokens->compute($doc);
}

# ── Signature Help Handler ──────────────────────

sub _handle_signature_help ($self, $params) {
    my $uri  = $params->{textDocument}{uri};
    my $doc  = $self->{documents}{$uri} // return undef;
    my $pos  = $params->{position};
    my $line = $pos->{line};
    my $col  = $pos->{character};

    $doc->analyze(workspace_registry => $self->{workspace} && $self->{workspace}->registry);

    my $ctx = $doc->signature_context($line, $col) // return undef;
    my $sym = $doc->find_function_symbol($ctx->{name});

    # Fallback: search workspace registry for imported/cross-package functions
    if (!$sym && $self->{workspace}) {
        my $reg = $self->{workspace}->registry;
        my $sig = $reg->search_function_by_name($ctx->{name});
        if ($sig) {
            $sym = Typist::LSP::Document::_synthesize_function_symbol($ctx->{name}, $sig);
        }
    }

    return undef unless $sym;
    return undef unless ($sym->{kind} // '') eq 'function';

    my $params_expr  = $sym->{params_expr} // [];
    my $returns_expr = $sym->{returns_expr};

    # Build label: add(Int, Int) -> Int
    my $label = "$sym->{name}(" . join(', ', @$params_expr) . ')';
    $label .= " -> $returns_expr" if $returns_expr;

    # Build parameter labels
    my @param_labels = map { +{ label => $_ } } @$params_expr;

    +{
        signatures => [+{
            label      => $label,
            parameters => \@param_labels,
        }],
        activeSignature => 0,
        activeParameter => $ctx->{active_parameter},
    };
}

# ── Definition Handler ──────────────────────────

sub _handle_definition ($self, $params) {
    my $uri  = $params->{textDocument}{uri};
    my $doc  = $self->{documents}{$uri} // return undef;
    my $pos  = $params->{position};
    my $line = $pos->{line};
    my $col  = $pos->{character};

    $doc->analyze(workspace_registry => $self->{workspace} && $self->{workspace}->registry);

    # Try same-file definition first
    if (my $def = $doc->definition_at($line, $col)) {
        return +{
            uri   => $def->{uri},
            range => +{
                start => +{ line => $def->{line}, character => $def->{col} },
                end   => +{ line => $def->{line}, character => $def->{col} + length($def->{name}) },
            },
        };
    }

    # Fallback: workspace cross-file definition
    if ($self->{workspace}) {
        my $word = $doc->word_at($line, $col);
        if ($word) {
            (my $bare = $word) =~ s/^[\$\@%]//;
            if (my $def = $self->{workspace}->find_definition($bare)) {
                return +{
                    uri   => $def->{uri},
                    range => +{
                        start => +{ line => $def->{line}, character => $def->{col} },
                        end   => +{ line => $def->{line}, character => $def->{col} + length($def->{name}) },
                    },
                };
            }
        }
    }

    undef;
}

# ── Document Symbol Handler ────────────────────

sub _handle_document_symbol ($self, $params) {
    my $uri = $params->{textDocument}{uri};
    my $doc = $self->{documents}{$uri} // return [];

    $doc->analyze(workspace_registry => $self->{workspace} && $self->{workspace}->registry);
    $doc->document_symbols;
}

# ── References Handler ──────────────────────────

sub _handle_references ($self, $params) {
    my $uri  = $params->{textDocument}{uri};
    my $doc  = $self->{documents}{$uri} // return undef;
    my $line = $params->{position}{line};
    my $col  = $params->{position}{character};

    my $word = $doc->word_at($line, $col) // return undef;
    (my $bare = $word) =~ s/^[\$\@%]//;

    my $refs = $self->{workspace}
        ? $self->{workspace}->find_all_references($bare, $self->{documents})
        : $doc->find_references($bare);

    my @locations = map {
        +{
            uri   => $_->{uri},
            range => +{
                start => +{ line => $_->{line}, character => $_->{col} },
                end   => +{ line => $_->{line}, character => $_->{col} + $_->{len} },
            },
        }
    } @$refs;

    \@locations;
}

# ── Rename Handler ──────────────────────────────

sub _handle_rename ($self, $params) {
    my $uri      = $params->{textDocument}{uri};
    my $doc      = $self->{documents}{$uri} // return undef;
    my $line     = $params->{position}{line};
    my $col      = $params->{position}{character};
    my $new_name = $params->{newName};

    my $word = $doc->word_at($line, $col) // return undef;
    (my $bare = $word) =~ s/^[\$\@%]//;

    my $refs = $self->{workspace}
        ? $self->{workspace}->find_all_references($bare, $self->{documents})
        : $doc->find_references($bare);

    my %changes;
    for my $ref (@$refs) {
        push @{$changes{$ref->{uri}}}, +{
            range => +{
                start => +{ line => $ref->{line}, character => $ref->{col} },
                end   => +{ line => $ref->{line}, character => $ref->{col} + $ref->{len} },
            },
            newText => $new_name,
        };
    }

    +{ changes => \%changes };
}

# ── Diagnostics Publishing ──────────────────────

sub _publish_diagnostics ($self, $doc) {
    my $result = eval {
        $doc->analyze(
            workspace_registry => $self->{workspace} && $self->{workspace}->registry,
        );
    };
    if ($@) {
        my $err = "$@";
        chomp $err;
        $self->{log}->error("analyze failed for @{[$doc->uri]}: $err");
        # Publish empty diagnostics to clear stale markers
        $self->{transport}->send_notification('textDocument/publishDiagnostics', +{
            uri         => $doc->uri,
            diagnostics => [],
        });
        return;
    }

    my @lsp_diags;
    for my $d ($result->{diagnostics}->@*) {
        my $line = ($d->{line} // 1) - 1;  # Convert to 0-indexed
        $line = 0 if $line < 0;

        my $start_col = ($d->{col} // 1) - 1;  # Convert 1-indexed to 0-indexed
        $start_col = 0 if $start_col < 0;

        my $end_line = defined $d->{end_line} ? ($d->{end_line} - 1) : $line;
        $end_line = 0 if $end_line < 0;

        my $end_col = defined $d->{end_col} ? ($d->{end_col} - 1) : ($start_col + 20);
        # If we don't have end_col, span 20 chars from start as a reasonable highlight width

        my $diag = +{
            range => +{
                start => +{ line => $line, character => $start_col },
                end   => +{ line => $end_line, character => $end_col },
            },
            severity => _lsp_severity($d->{severity}),
            source   => 'typist',
            message  => $d->{message},
        };

        if ($d->{related} && @{$d->{related}}) {
            $diag->{relatedInformation} = [map { +{
                location => +{
                    uri   => $_->{uri} // $doc->uri,
                    range => +{
                        start => +{ line => ($_->{line} // 1) - 1, character => ($_->{col} // 1) - 1 },
                        end   => +{ line => ($_->{line} // 1) - 1, character => ($_->{col} // 1) + 19 },
                    },
                },
                message => $_->{message},
            } } @{$d->{related}}];
        }

        push @lsp_diags, $diag;
    }

    $self->{log}->debug("publishing @{[scalar @lsp_diags]} diagnostics for @{[$doc->uri]}");

    $self->{transport}->send_notification('textDocument/publishDiagnostics', +{
        uri         => $doc->uri,
        diagnostics => \@lsp_diags,
    });
}

# Map internal severity (1=critical..4=info) to LSP severity (1=Error..4=Hint)
sub _lsp_severity ($internal) {
    $internal // 3;
}

# ── URI Utilities ───────────────────────────────

# Convert file:// URI to filesystem path with percent-decoding.
sub _uri_to_path ($uri) {
    $uri =~ s{^file://}{};
    $uri =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $uri;
}

1;
