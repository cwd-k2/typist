use v5.40;
use Test::More;
use lib 'lib';

use File::Temp qw(tempdir);
use File::Path qw(make_path);

use Typist::LSP::Server;
use Typist::LSP::Transport;
use Typist::LSP::Logger;

# Helper: capture sent messages
my @sent;
{
    no warnings 'redefine';
    my $orig_send = \&Typist::LSP::Transport::send_notification;
    *Typist::LSP::Transport::send_notification = sub ($self, $method, $params) {
        push @sent, +{ method => $method, params => $params };
    };
}

# Helper: create a fresh server with open docs
sub _setup_server_docs ($dir, @docs) {
    make_path("$dir/lib");

    my $server = Typist::LSP::Server->new(logger => Typist::LSP::Logger->new(level => 'off'));
    $server->_handle_initialize(+{ rootUri => "file://$dir" });

    for my $doc (@docs) {
        $server->_handle_did_open(+{
            textDocument => +{
                uri     => $doc->{uri},
                text    => $doc->{text},
                version => 1,
            },
        });
    }

    @sent = ();  # Clear diagnostics from initial open
    $server;
}

# ── Body-only change: selective re-diagnosis ─────

subtest 'body-only change re-diagnoses saved file only' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $server = _setup_server_docs($dir,
        +{
            uri  => 'file:///doc_a.pm',
            text => "package A;\nuse v5.40;\nsub foo :sig((Int) -> Int) (\$x) { \$x }\n",
        },
        +{
            uri  => 'file:///doc_b.pm',
            text => "package B;\nuse v5.40;\nsub bar :sig((Str) -> Str) (\$x) { \$x }\n",
        },
    );

    # Save doc_a with same signature, different body
    $server->_handle_did_save(+{
        textDocument => +{ uri => 'file:///doc_a.pm' },
        text => "package A;\nuse v5.40;\nsub foo :sig((Int) -> Int) (\$x) { \$x + 1 }\n",
    });

    my @diag_msgs = grep { $_->{method} eq 'textDocument/publishDiagnostics' } @sent;
    my %seen_uris = map { $_->{params}{uri} => 1 } @diag_msgs;

    ok $seen_uris{'file:///doc_a.pm'}, 'saved doc re-diagnosed';
    ok !$seen_uris{'file:///doc_b.pm'}, 'other doc NOT re-diagnosed (body-only change)';
};

# ── Signature change: downstream-only re-diagnosis ──

subtest 'signature change re-diagnoses downstream open docs only' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $server = _setup_server_docs($dir,
        +{
            uri  => 'file:///doc_a.pm',
            text => "package A;\nuse v5.40;\nsub foo :sig((Int) -> Int) (\$x) { \$x }\n",
        },
        +{
            uri  => 'file:///doc_b.pm',
            text => "package B;\nuse v5.40;\nuse A;\nsub bar :sig((Int) -> Int) (\$x) { foo(\$x) }\n",
        },
        +{
            uri  => 'file:///doc_c.pm',
            text => "package C;\nuse v5.40;\nsub baz :sig((Str) -> Str) (\$x) { \$x }\n",
        },
    );

    # Save doc_a with changed signature (Int -> Str instead of Int -> Int)
    $server->_handle_did_save(+{
        textDocument => +{ uri => 'file:///doc_a.pm' },
        text => "package A;\nuse v5.40;\nsub foo :sig((Int) -> Str) (\$x) { \"\$x\" }\n",
    });

    my @diag_msgs = grep { $_->{method} eq 'textDocument/publishDiagnostics' } @sent;
    my %seen_uris = map { $_->{params}{uri} => 1 } @diag_msgs;
    ok $seen_uris{'file:///doc_a.pm'}, 'doc_a re-diagnosed';
    ok $seen_uris{'file:///doc_b.pm'}, 'dependent doc_b re-diagnosed';
    ok !$seen_uris{'file:///doc_c.pm'}, 'unrelated doc_c not re-diagnosed';
};

# ── Typedef added: downstream-only re-diagnosis ──

subtest 'typedef added re-diagnoses downstream open docs only' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $server = _setup_server_docs($dir,
        +{
            uri  => 'file:///doc_a.pm',
            text => "package A;\nuse v5.40;\nsub foo :sig((Int) -> Int) (\$x) { \$x }\n",
        },
        +{
            uri  => 'file:///doc_b.pm',
            text => "package B;\nuse v5.40;\nuse A;\nsub bar :sig((Int) -> Int) (\$x) { foo(\$x) }\n",
        },
        +{
            uri  => 'file:///doc_c.pm',
            text => "package C;\nuse v5.40;\nsub baz :sig((Str) -> Str) (\$x) { \$x }\n",
        },
    );

    # Save doc_a with a new typedef
    $server->_handle_did_save(+{
        textDocument => +{ uri => 'file:///doc_a.pm' },
        text => "package A;\nuse v5.40;\ntypedef Age => 'Int';\nsub foo :sig((Int) -> Int) (\$x) { \$x }\n",
    });

    my @diag_msgs = grep { $_->{method} eq 'textDocument/publishDiagnostics' } @sent;
    my %seen_uris = map { $_->{params}{uri} => 1 } @diag_msgs;
    ok $seen_uris{'file:///doc_a.pm'}, 'doc_a re-diagnosed';
    ok $seen_uris{'file:///doc_b.pm'}, 'dependent doc_b re-diagnosed';
    ok !$seen_uris{'file:///doc_c.pm'}, 'unrelated doc_c not re-diagnosed';
};

# ── Workspace update on save ─────────────────────

subtest 'didSave updates workspace index' => sub {
    @sent = ();

    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    my $server = Typist::LSP::Server->new(logger => Typist::LSP::Logger->new(level => 'off'));
    $server->_handle_initialize(+{
        rootUri => "file://$dir",
    });

    my $path = "$dir/lib/Defs.pm";

    # Open and save a file with typedef
    $server->_handle_did_open(+{
        textDocument => +{
            uri     => "file://$path",
            text    => "package Defs;\ntypedef Score => 'Int';\n1;\n",
            version => 1,
        },
    });

    $server->_handle_did_save(+{
        textDocument => +{ uri => "file://$path" },
        text => "package Defs;\ntypedef Score => 'Int';\n1;\n",
    });

    # Workspace should now have Score
    ok $server->{workspace}->registry->has_alias('Score'), 'Score registered via save';
};

subtest 'transitive signature change re-diagnoses downstream chain only' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $server = _setup_server_docs($dir,
        +{
            uri  => 'file:///doc_a.pm',
            text => "package A;\nuse v5.40;\nsub foo :sig((Int) -> Int) (\$x) { \$x }\n",
        },
        +{
            uri  => 'file:///doc_b.pm',
            text => "package B;\nuse v5.40;\nuse A;\nsub bar :sig((Int) -> Int) (\$x) { foo(\$x) }\n",
        },
        +{
            uri  => 'file:///doc_c.pm',
            text => "package C;\nuse v5.40;\nuse B;\nsub baz :sig((Int) -> Int) (\$x) { bar(\$x) }\n",
        },
        +{
            uri  => 'file:///doc_d.pm',
            text => "package D;\nuse v5.40;\nsub qux :sig((Str) -> Str) (\$x) { \$x }\n",
        },
    );

    $server->_handle_did_save(+{
        textDocument => +{ uri => 'file:///doc_a.pm' },
        text => "package A;\nuse v5.40;\nsub foo :sig((Int) -> Str) (\$x) { \"\$x\" }\n",
    });

    my @diag_msgs = grep { $_->{method} eq 'textDocument/publishDiagnostics' } @sent;
    my %seen_uris = map { $_->{params}{uri} => 1 } @diag_msgs;

    ok $seen_uris{'file:///doc_a.pm'}, 'changed file re-diagnosed';
    ok $seen_uris{'file:///doc_b.pm'}, 'direct dependent re-diagnosed';
    ok $seen_uris{'file:///doc_c.pm'}, 'transitive dependent re-diagnosed';
    ok !$seen_uris{'file:///doc_d.pm'}, 'unrelated file not re-diagnosed';
};

subtest 'transitive body-only change does not re-diagnose downstream chain' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $server = _setup_server_docs($dir,
        +{
            uri  => 'file:///doc_a.pm',
            text => "package A;\nuse v5.40;\nsub foo :sig((Int) -> Int) (\$x) { \$x }\n",
        },
        +{
            uri  => 'file:///doc_b.pm',
            text => "package B;\nuse v5.40;\nuse A;\nsub bar :sig((Int) -> Int) (\$x) { foo(\$x) }\n",
        },
        +{
            uri  => 'file:///doc_c.pm',
            text => "package C;\nuse v5.40;\nuse B;\nsub baz :sig((Int) -> Int) (\$x) { bar(\$x) }\n",
        },
    );

    $server->_handle_did_save(+{
        textDocument => +{ uri => 'file:///doc_a.pm' },
        text => "package A;\nuse v5.40;\nsub foo :sig((Int) -> Int) (\$x) { \$x + 1 }\n",
    });

    my @diag_msgs = grep { $_->{method} eq 'textDocument/publishDiagnostics' } @sent;
    my %seen_uris = map { $_->{params}{uri} => 1 } @diag_msgs;

    ok $seen_uris{'file:///doc_a.pm'}, 'saved file re-diagnosed';
    ok !$seen_uris{'file:///doc_b.pm'}, 'direct dependent not re-diagnosed for body-only change';
    ok !$seen_uris{'file:///doc_c.pm'}, 'transitive dependent not re-diagnosed for body-only change';
};

done_testing;
