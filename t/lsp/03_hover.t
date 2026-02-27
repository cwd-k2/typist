use v5.40;
use Test::More;
use lib 'lib';

use JSON::PP;
use Typist::LSP::Transport;
use Typist::LSP::Server;

my $JSON = JSON::PP->new->utf8->canonical;

sub frame ($msg) {
    my $body = $JSON->encode($msg);
    "Content-Length: " . length($body) . "\r\n\r\n$body";
}

sub run_session (@messages) {
    my $input = join('', map { frame($_) } @messages);
    open my $in, '<', \$input or die;
    my $out = '';
    open my $out_fh, '>', \$out or die;

    my $transport = Typist::LSP::Transport->new(in => $in, out => $out_fh);
    my $server = Typist::LSP::Server->new(transport => $transport);
    $server->run;

    my @results;
    while ($out =~ /Content-Length: (\d+)\r\n\r\n/g) {
        my $len = $1;
        my $pos = pos($out);
        my $body = substr($out, $pos, $len);
        push @results, $JSON->decode($body);
        pos($out) = $pos + $len;
    }

    @results;
}

# ── Hover on function ───────────────────────────

subtest 'hover returns function signature' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :Params(Int, Int) :Returns(Int) ($a, $b) { $a + $b }
PERL

    my @results = run_session(
        +{ jsonrpc => '2.0', id => 1, method => 'initialize', params => +{} },
        +{ jsonrpc => '2.0', method => 'initialized', params => +{} },
        +{
            jsonrpc => '2.0',
            method  => 'textDocument/didOpen',
            params  => +{
                textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
            },
        },
        +{
            jsonrpc => '2.0', id => 2,
            method  => 'textDocument/hover',
            params  => +{
                textDocument => +{ uri => 'file:///test.pm' },
                position => +{ line => 1, character => 5 },  # on 'add'
            },
        },
        +{ jsonrpc => '2.0', id => 3, method => 'shutdown' },
        +{ jsonrpc => '2.0', method => 'exit' },
    );

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/sub add/, 'contains function name';
    like $hover->{result}{contents}{value}, qr/Int/, 'contains type info';
};

# ── Hover on typedef ────────────────────────────

subtest 'hover returns typedef info' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
PERL

    my @results = run_session(
        +{ jsonrpc => '2.0', id => 1, method => 'initialize', params => +{} },
        +{ jsonrpc => '2.0', method => 'initialized', params => +{} },
        +{
            jsonrpc => '2.0',
            method  => 'textDocument/didOpen',
            params  => +{
                textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
            },
        },
        +{
            jsonrpc => '2.0', id => 2,
            method  => 'textDocument/hover',
            params  => +{
                textDocument => +{ uri => 'file:///test.pm' },
                position => +{ line => 1, character => 10 },  # on typedef line
            },
        },
        +{ jsonrpc => '2.0', id => 3, method => 'shutdown' },
        +{ jsonrpc => '2.0', method => 'exit' },
    );

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/type Age/, 'contains typedef';
};

done_testing;
