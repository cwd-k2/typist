package Typist::LSP::Server;
use v5.40;

our $VERSION = '0.01';

use Typist::LSP::Transport;
use Typist::LSP::Document;
use Typist::LSP::Workspace;
use Typist::LSP::Hover;
use Typist::LSP::Completion;
use Typist::LSP::SemanticTokens;
use Typist::LSP::CodeAction;
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
    'textDocument/codeAction'             => \&_handle_code_action,
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

# ── Accessors ────────────────────────────────────

sub _ws_registry ($self) { $self->{workspace} && $self->{workspace}->registry }

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

    # Track client capabilities for refresh support
    my $caps = $params->{capabilities} // +{};
    $self->{_client_caps} = $caps;
    $self->{_inlay_refresh} = $caps->{workspace}{inlayHint}{refreshSupport} ? 1 : 0;

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
            codeActionProvider     => +{
                codeActionKinds => ['quickfix'],
            },
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
    $self->_refresh_inlay_hints;

    undef;
}

sub _handle_did_save ($self, $params) {
    my $uri = $params->{textDocument}{uri};
    my $doc = $self->{documents}{$uri} // return undef;

    # Update content if provided
    if (my $text = $params->{text}) {
        $doc->update($text, $doc->version);
    }

    # Update workspace index — returns extracted data for the saved file
    my $path = _uri_to_path($uri);
    my $extracted = $self->{workspace}
        ? $self->{workspace}->update_file($path, $doc->content)
        : undef;
    $self->{log}->debug("didSave $uri -> workspace updated");

    # Invalidate and re-diagnose all open documents (cross-file types may have changed)
    for my $other_doc (values $self->{documents}->%*) {
        $other_doc->invalidate;
        # Pass extracted only to the saved file itself (same source)
        if ($other_doc->uri eq $uri && $extracted) {
            $self->_publish_diagnostics_with_extracted($other_doc, $extracted);
        } else {
            $self->_publish_diagnostics($other_doc);
        }
    }

    $self->_refresh_inlay_hints;

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
    $doc->analyze(workspace_registry => $self->_ws_registry);

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

        # Collect type variable names from document-level generic declarations
        my @doc_type_vars;
        my $result = $doc->result;
        if ($result && $result->{extracted}) {
            for my $fn (values $result->{extracted}{functions}->%*) {
                push @doc_type_vars, ($fn->{generics} // [])->@*;
            }
        }

        my $items = Typist::LSP::Completion->complete(
            $ctx, \@typedefs, \@effects, \@typeclasses, \@doc_type_vars,
        );
        return +{ items => $items };
    }

    # Code completion context (type-aware)
    if (my $code_ctx = $doc->code_completion_at($line, $col)) {
        $doc->analyze(workspace_registry => $self->_ws_registry)
            unless $doc->result;
        my $registry = $self->_ws_registry;
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

    $doc->analyze(workspace_registry => $self->_ws_registry);

    my $start = $range->{start}{line};
    my $end   = $range->{end}{line};

    $doc->inlay_hints($start, $end);
}

# ── Semantic Tokens Handler ────────────────────

sub _handle_semantic_tokens ($self, $params) {
    my $uri = $params->{textDocument}{uri};
    my $doc = $self->{documents}{$uri} // return +{ data => [] };

    $doc->analyze(workspace_registry => $self->_ws_registry);

    Typist::LSP::SemanticTokens->compute($doc);
}

# ── Signature Help Handler ──────────────────────

sub _handle_signature_help ($self, $params) {
    my $uri  = $params->{textDocument}{uri};
    my $doc  = $self->{documents}{$uri} // return undef;
    my $pos  = $params->{position};
    my $line = $pos->{line};
    my $col  = $pos->{character};

    $doc->analyze(workspace_registry => $self->_ws_registry);

    my $ctx = $doc->signature_context($line, $col) // return undef;
    my $sym;

    # Method call: $var->method( → resolve variable type for signature
    if ($ctx->{is_method}) {
        my $type_str = $doc->_resolve_var_type($ctx->{var}, $line);
        if ($type_str) {
            my $type = eval { Typist::Parser->parse($type_str) };
            if ($type && !$@) {
                my $reg = $self->_ws_registry;
                my $resolved = $doc->_resolve_type_deep($type, $reg);
                if ($resolved && $resolved->is_struct) {
                    my $struct_pkg = "Typist::Struct::" . $resolved->name;
                    my $method_sig = $reg->lookup_function($struct_pkg, $ctx->{name});
                    $sym = Typist::LSP::Document::_synthesize_function_symbol($ctx->{name}, $method_sig) if $method_sig;
                }
            }
        }
    }

    if (!$sym) {
        $sym = $doc->find_function_symbol($ctx->{name});
    }

    # Fallback: search workspace registry for imported/cross-package functions
    if (!$sym) {
        my $reg = $self->_ws_registry;
        my $sig = $reg && $reg->search_function_by_name($ctx->{name});
        if ($sig) {
            $sym = Typist::LSP::Document::_synthesize_function_symbol($ctx->{name}, $sig);
        }
    }

    return undef unless $sym;
    return undef unless ($sym->{kind} // '') eq 'function';

    # Struct constructor: show field-based signature
    if ($sym->{struct_constructor}) {
        my $reg = $self->_ws_registry;
        my $struct = $reg ? $reg->lookup_struct($sym->{name}) : undef;
        if ($struct) {
            my @params;
            my %req = $struct->required_fields;
            my %opt = $struct->optional_fields;
            for my $f (sort keys %req) {
                push @params, "$f => " . $req{$f}->to_string;
            }
            for my $f (sort keys %opt) {
                push @params, "$f? => " . $opt{$f}->to_string;
            }
            my $label = "$sym->{name}(" . join(', ', @params) . ")";
            return +{
                signatures => [+{ label => $label, parameters => [map { +{ label => $_ } } @params] }],
                activeSignature => 0,
                activeParameter => $ctx->{active_parameter},
            };
        }
    }

    my $params_expr  = $sym->{params_expr} // [];
    my $returns_expr = $sym->{returns_expr};

    # Build label: add(Int, Int) -> Int ![Console]
    my $label = "$sym->{name}(" . join(', ', @$params_expr) . ')';
    $label .= " -> $returns_expr" if $returns_expr;
    $label .= " !$sym->{eff_expr}" if $sym->{eff_expr};

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

    $doc->analyze(workspace_registry => $self->_ws_registry);

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

            # Qualified Effect::op → try effect name
            if ($bare =~ /\A([A-Z]\w*)::\w+\z/) {
                if (my $def = $self->{workspace}->find_definition($1)) {
                    return +{
                        uri   => $def->{uri},
                        range => +{
                            start => +{ line => $def->{line}, character => $def->{col} },
                            end   => +{ line => $def->{line}, character => $def->{col} + length($def->{name}) },
                        },
                    };
                }
            }

            # Struct field accessor: $var->field → find struct definition
            if ($bare !~ /::/) {
                my $text = ($doc->lines)->[$line] // '';
                if ($text =~ /(\$\w+)\s*->\s*\Q$bare\E/) {
                    my $type_str = $doc->_resolve_var_type($1, $line);
                    if ($type_str) {
                        (my $type_name = $type_str) =~ s/\[.*\]//;
                        if (my $def = $self->{workspace}->find_definition($type_name)) {
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
            }

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

    $doc->analyze(workspace_registry => $self->_ws_registry);
    $doc->document_symbols;
}

# ── References Handler ──────────────────────────

sub _handle_references ($self, $params) {
    my $uri  = $params->{textDocument}{uri};
    my $doc  = $self->{documents}{$uri} // return undef;
    my $line = $params->{position}{line};
    my $col  = $params->{position}{character};

    $doc->analyze(workspace_registry => $self->_ws_registry);

    my $word = $doc->word_at($line, $col) // return undef;

    my $refs;
    if ($word =~ /^[\$\@%]/) {
        # Variable: scope-aware single-file search
        $refs = $doc->find_scoped_references($word, $line);
    } else {
        (my $bare = $word) =~ s/^[\$\@%]//;
        $refs = $self->{workspace}
            ? $self->{workspace}->find_all_references($bare, $self->{documents})
            : $doc->find_references($bare);
    }

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

    $doc->analyze(workspace_registry => $self->_ws_registry);

    my $word = $doc->word_at($line, $col) // return undef;

    my $refs;
    if ($word =~ /^[\$\@%]/) {
        # Variable: scope-aware single-file rename
        $refs = $doc->find_scoped_references($word, $line);
    } else {
        (my $bare = $word) =~ s/^[\$\@%]//;
        $refs = $self->{workspace}
            ? $self->{workspace}->find_all_references($bare, $self->{documents})
            : $doc->find_references($bare);
    }

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

# ── Code Action Handler ─────────────────────────

sub _handle_code_action ($self, $params) {
    my $uri     = $params->{textDocument}{uri};
    my $doc     = $self->{documents}{$uri} // return [];
    my $context = $params->{context} // +{};

    my $diagnostics = $context->{diagnostics} // [];

    my $registry = $self->_ws_registry;
    Typist::LSP::CodeAction->actions_for_diagnostics($diagnostics, $doc, $registry);
}

# ── Diagnostics Publishing ──────────────────────

sub _publish_diagnostics_with_extracted ($self, $doc, $extracted) {
    my $result = eval {
        $doc->analyze(
            workspace_registry => $self->_ws_registry,
            extracted          => $extracted,
        );
    };
    if ($@) {
        my $err = "$@";
        chomp $err;
        $self->{log}->error("analyze failed for @{[$doc->uri]}: $err");
        $self->{transport}->send_notification('textDocument/publishDiagnostics', +{
            uri         => $doc->uri,
            diagnostics => [],
        });
        return;
    }
    $self->_emit_diagnostics($doc, $result);
}

sub _publish_diagnostics ($self, $doc) {
    my $result = eval {
        $doc->analyze(
            workspace_registry => $self->_ws_registry,
        );
    };
    if ($@) {
        my $err = "$@";
        chomp $err;
        $self->{log}->error("analyze failed for @{[$doc->uri]}: $err");
        $self->{transport}->send_notification('textDocument/publishDiagnostics', +{
            uri         => $doc->uri,
            diagnostics => [],
        });
        return;
    }
    $self->_emit_diagnostics($doc, $result);
}

sub _refresh_inlay_hints ($self) {
    return unless $self->{_inlay_refresh};
    $self->{transport}->send_notification('workspace/inlayHint/refresh', undef);
}

sub _emit_diagnostics ($self, $doc, $result) {
    my @lsp_diags;
    for my $d ($result->{diagnostics}->@*) {
        my $line = ($d->{line} // 1) - 1;
        $line = 0 if $line < 0;

        my $start_col = ($d->{col} // 1) - 1;
        $start_col = 0 if $start_col < 0;

        my $end_line = defined $d->{end_line} ? ($d->{end_line} - 1) : $line;
        $end_line = 0 if $end_line < 0;

        my $end_col = defined $d->{end_col} ? ($d->{end_col} - 1) : ($start_col + 20);

        my $diag = +{
            range => +{
                start => +{ line => $line, character => $start_col },
                end   => +{ line => $end_line, character => $end_col },
            },
            severity => _lsp_severity($d->{severity}),
            source   => 'typist',
            message  => $d->{message},
            data     => +{
                _typist_kind => $d->{kind},
                ($d->{suggestions}   ? (_suggestions   => $d->{suggestions})   : ()),
                ($d->{expected_type} ? (_expected_type => $d->{expected_type}) : ()),
                ($d->{actual_type}   ? (_actual_type   => $d->{actual_type})   : ()),
            },
        };

        if ($d->{related} && @{$d->{related}}) {
            $diag->{relatedInformation} = [map { +{
                location => +{
                    uri   => $_->{uri} // $doc->uri,
                    range => +{
                        start => +{ line => ($_->{line} // 1) - 1, character => ($_->{col} // 1) - 1 },
                        end   => +{ line => ($_->{line} // 1) - 1,
                                    character => defined $_->{end_col} ? ($_->{end_col} - 1) : (($_->{col} // 1) + 19) },
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

sub _uri_to_path ($uri) { Typist::LSP::Transport::uri_to_path($uri) }

1;

__END__

=head1 NAME

Typist::LSP::Server - Language Server Protocol implementation for Typist

=head1 SYNOPSIS

    use Typist::LSP::Server;

    my $server = Typist::LSP::Server->new;
    $server->run;

=head1 DESCRIPTION

Typist::LSP::Server implements the Language Server Protocol message
dispatch loop for the Typist type system. It manages document lifecycle,
delegates analysis to L<Typist::LSP::Document>, and coordinates
workspace-level features through L<Typist::LSP::Workspace>.

=head1 CAPABILITIES

The server advertises the following LSP capabilities:

=over 4

=item B<textDocumentSync> - Full content synchronization (open/change/save/close)

=item B<hoverProvider> - Type signature display on hover

=item B<completionProvider> - Type annotation and code completion (triggers: C<(>, C<[>, C<,>, C<|>, C<&>, C<E<gt>>, C<{>, C<:>)

=item B<documentSymbolProvider> - Document symbol outline

=item B<definitionProvider> - Go to definition (same-file and cross-file)

=item B<signatureHelpProvider> - Function signature help (triggers: C<(>, C<,>)

=item B<referencesProvider> - Find all references

=item B<renameProvider> - Symbol rename across workspace

=item B<inlayHintProvider> - Inferred type hints for variables

=item B<codeActionProvider> - Quick-fix code actions (effect mismatch, type suggestions)

=item B<semanticTokensProvider> - Semantic token classification for syntax highlighting

=back

=head1 CONSTRUCTOR

=head2 new

    my $server = Typist::LSP::Server->new(
        transport => $transport,   # optional, defaults to Typist::LSP::Transport->new
        logger    => $logger,      # optional, defaults to Typist::LSP::Logger->new
    );

=head1 METHODS

=head2 run

    $server->run;

Enter the main message loop. Reads JSON-RPC messages from transport,
dispatches to handlers, and sends responses. Returns when the client
sends an C<exit> notification.

=head2 did_shutdown

    my $bool = $server->did_shutdown;

Returns true if the server has received a C<shutdown> request.

=head1 SEE ALSO

L<Typist::LSP::Document>, L<Typist::LSP::Workspace>, L<Typist::LSP::Transport>

=cut
