use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use JSON::PP;
use Typist::LSP::Transport;
use Test::Typist::LSP qw(frame);

my $JSON = JSON::PP->new->utf8->canonical;

# ── Read message ─────────────────────────────────

subtest 'read_message parses framed JSON-RPC' => sub {
    my $msg = +{ jsonrpc => '2.0', method => 'initialize', id => 1, params => +{} };
    my $input = frame($msg);

    open my $in, '<', \$input or die;
    my $out = '';
    open my $out_fh, '>', \$out or die;

    my $transport = Typist::LSP::Transport->new(in => $in, out => $out_fh);
    my $result = $transport->read_message;

    ok $result, 'message read';
    is $result->{method}, 'initialize', 'method is initialize';
    is $result->{id}, 1, 'id is 1';
};

# ── Send response ────────────────────────────────

subtest 'send_response writes framed JSON-RPC' => sub {
    my $input = '';
    open my $in, '<', \$input or die;
    my $out = '';
    open my $out_fh, '>', \$out or die;

    my $transport = Typist::LSP::Transport->new(in => $in, out => $out_fh);
    $transport->send_response(1, +{ capabilities => +{} });

    like $out, qr/Content-Length: \d+\r\n\r\n/, 'has framing';
    my ($body) = $out =~ /\r\n\r\n(.+)/s;
    my $parsed = $JSON->decode($body);
    is $parsed->{id}, 1, 'response id';
    is $parsed->{jsonrpc}, '2.0', 'jsonrpc version';
    ok exists $parsed->{result}, 'has result';
};

# ── Send notification ────────────────────────────

subtest 'send_notification writes method without id' => sub {
    my $input = '';
    open my $in, '<', \$input or die;
    my $out = '';
    open my $out_fh, '>', \$out or die;

    my $transport = Typist::LSP::Transport->new(in => $in, out => $out_fh);
    $transport->send_notification('textDocument/publishDiagnostics', +{ uri => 'file:///test.pm' });

    my ($body) = $out =~ /\r\n\r\n(.+)/s;
    my $parsed = $JSON->decode($body);
    is $parsed->{method}, 'textDocument/publishDiagnostics', 'notification method';
    ok !exists $parsed->{id}, 'no id in notification';
};

# ── Send error ───────────────────────────────────

subtest 'send_error writes error response' => sub {
    my $input = '';
    open my $in, '<', \$input or die;
    my $out = '';
    open my $out_fh, '>', \$out or die;

    my $transport = Typist::LSP::Transport->new(in => $in, out => $out_fh);
    $transport->send_error(2, -32601, 'Method not found');

    my ($body) = $out =~ /\r\n\r\n(.+)/s;
    my $parsed = $JSON->decode($body);
    is $parsed->{id}, 2, 'error response id';
    is $parsed->{error}{code}, -32601, 'error code';
    like $parsed->{error}{message}, qr/not found/i, 'error message';
};

# ── Multiple messages ────────────────────────────

subtest 'reads multiple sequential messages' => sub {
    my $msg1 = frame(+{ jsonrpc => '2.0', method => 'a', id => 1 });
    my $msg2 = frame(+{ jsonrpc => '2.0', method => 'b', id => 2 });
    my $input = $msg1 . $msg2;

    open my $in, '<', \$input or die;
    my $out = '';
    open my $out_fh, '>', \$out or die;

    my $transport = Typist::LSP::Transport->new(in => $in, out => $out_fh);

    my $r1 = $transport->read_message;
    is $r1->{method}, 'a', 'first message';

    my $r2 = $transport->read_message;
    is $r2->{method}, 'b', 'second message';
};

# ── Content-Length limit ────────────────────────

subtest 'oversized Content-Length returns undef' => sub {
    # Craft a header claiming 20MB — exceeds 10MB limit
    my $input = "Content-Length: 20971520\r\n\r\n";
    open my $in, '<', \$input or die;
    my $out = '';
    open my $out_fh, '>', \$out or die;

    my $transport = Typist::LSP::Transport->new(in => $in, out => $out_fh);
    my $result = $transport->read_message;
    ok !defined $result, 'oversized Content-Length returns undef';
};

done_testing;
