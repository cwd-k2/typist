package Test::Typist::LSP;
use v5.40;

use Exporter 'import';
use JSON::PP;

use Typist::LSP::Transport;
use Typist::LSP::Server;
use Typist::LSP::Document;
use Typist::LSP::Logger;

our @EXPORT_OK = qw(
    frame  parse_responses  run_session
    lsp_request  lsp_notification  init_shutdown_wrap
    make_doc
);

my $JSON = JSON::PP->new->utf8->canonical;

# ── Framing ─────────────────────────────────────

# Encode a hashref as a Content-Length–framed JSON-RPC message.
sub frame ($msg) {
    my $body = $JSON->encode($msg);
    "Content-Length: " . length($body) . "\r\n\r\n$body";
}

# ── Response Parsing ────────────────────────────

# Parse framed byte stream into a list of decoded message hashrefs.
sub parse_responses ($raw) {
    my @results;
    while ($$raw =~ /Content-Length: (\d+)\r\n\r\n/g) {
        my $len = $1;
        my $pos = pos($$raw);
        my $body = substr($$raw, $pos, $len);
        push @results, $JSON->decode($body);
        pos($$raw) = $pos + $len;
    }
    @results;
}

# ── Session Runner ──────────────────────────────

# Feed messages into an in-memory LSP server, return all responses.
sub run_session (@messages) {
    my $input = join('', map { frame($_) } @messages);
    open my $in, '<', \$input or die;
    my $out = '';
    open my $out_fh, '>', \$out or die;

    my $transport = Typist::LSP::Transport->new(in => $in, out => $out_fh);
    my $logger    = Typist::LSP::Logger->new(level => 'off');
    my $server    = Typist::LSP::Server->new(transport => $transport, logger => $logger);
    $server->run;

    parse_responses(\$out);
}

# ── Message Builders ────────────────────────────

sub lsp_request ($id, $method, $params = +{}) {
    +{ jsonrpc => '2.0', id => $id, method => $method, params => $params };
}

sub lsp_notification ($method, $params = +{}) {
    +{ jsonrpc => '2.0', method => $method, params => $params };
}

# ── Lifecycle Wrapper ───────────────────────────

# Wrap inner messages with initialize/initialized + shutdown/exit.
# Returns the full message list ready for run_session.
sub init_shutdown_wrap (@inner) {
    (
        lsp_request(1, 'initialize'),
        lsp_notification('initialized'),
        @inner,
        lsp_request(99, 'shutdown'),
        lsp_notification('exit'),
    );
}

# ── Document Factory ─────────────────────────────

# Create a lightweight Document from source text (no analysis).
sub make_doc ($source) {
    Typist::LSP::Document->new(
        uri     => 'file:///test.pl',
        content => $source,
        version => 1,
    );
}

1;
