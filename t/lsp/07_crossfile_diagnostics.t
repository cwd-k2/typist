use v5.40;
use Test::More;
use lib 'lib';

use File::Temp qw(tempdir);
use File::Path qw(make_path);

use Typist::LSP::Server;
use Typist::LSP::Transport;

# Helper: capture sent messages
my @sent;
{
    no warnings 'redefine';
    my $orig_send = \&Typist::LSP::Transport::send_notification;
    *Typist::LSP::Transport::send_notification = sub ($self, $method, $params) {
        push @sent, +{ method => $method, params => $params };
    };
}

# ── Re-diagnosis on save ────────────────────────

subtest 'didSave triggers re-diagnosis of all open docs' => sub {
    @sent = ();

    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    # Write a types file
    open my $fh, '>', "$dir/lib/Types.pm" or die;
    print $fh "package Types;\ntypedef Age => 'Int';\n1;\n";
    close $fh;

    my $server = Typist::LSP::Server->new;

    # Initialize
    $server->_handle_initialize(+{
        rootUri => "file://$dir",
    });

    # Open two documents
    $server->_handle_did_open(+{
        textDocument => +{
            uri     => 'file:///doc_a.pm',
            text    => "package A;\nuse v5.40;\nsub foo :Params(Int) :Returns(Int) (\$x) { \$x }\n",
            version => 1,
        },
    });

    $server->_handle_did_open(+{
        textDocument => +{
            uri     => 'file:///doc_b.pm',
            text    => "package B;\nuse v5.40;\nsub bar :Params(Str) :Returns(Str) (\$x) { \$x }\n",
            version => 1,
        },
    });

    @sent = ();  # Clear diagnostics from initial open

    # Save doc_a — should re-diagnose both docs
    $server->_handle_did_save(+{
        textDocument => +{ uri => 'file:///doc_a.pm' },
        text => "package A;\nuse v5.40;\nsub foo :Params(Int) :Returns(Int) (\$x) { \$x }\n",
    });

    # Should have published diagnostics for both documents
    my @diag_msgs = grep { $_->{method} eq 'textDocument/publishDiagnostics' } @sent;
    ok scalar @diag_msgs >= 2, 'diagnostics published for multiple documents on save';

    my %seen_uris = map { $_->{params}{uri} => 1 } @diag_msgs;
    ok $seen_uris{'file:///doc_a.pm'}, 'doc_a re-diagnosed';
    ok $seen_uris{'file:///doc_b.pm'}, 'doc_b re-diagnosed';
};

# ── Workspace update on save ─────────────────────

subtest 'didSave updates workspace index' => sub {
    @sent = ();

    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    my $server = Typist::LSP::Server->new;
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

done_testing;
