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

# ── Completion inside :Params(──────────────────

subtest 'completion inside :Params(' => sub {
    my $source = "use v5.40;\nsub foo :Params(";

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
            method  => 'textDocument/completion',
            params  => +{
                textDocument => +{ uri => 'file:///test.pm' },
                position => +{ line => 1, character => length('sub foo :Params(') },
            },
        },
        +{ jsonrpc => '2.0', id => 3, method => 'shutdown' },
        +{ jsonrpc => '2.0', method => 'exit' },
    );

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    ok $comp->{result}{items}, 'has items';

    my @labels = map { $_->{label} } @{$comp->{result}{items}};
    ok((grep { $_ eq 'Int' }      @labels), 'Int in completions');
    ok((grep { $_ eq 'Str' }      @labels), 'Str in completions');
    ok((grep { $_ eq 'ArrayRef' } @labels), 'ArrayRef in completions');
};

# ── Completion inside :Generic( ─────────────────

subtest 'completion inside :Generic(' => sub {
    my $source = "use v5.40;\nsub foo :Generic(";

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
            method  => 'textDocument/completion',
            params  => +{
                textDocument => +{ uri => 'file:///test.pm' },
                position => +{ line => 1, character => length('sub foo :Generic(') },
            },
        },
        +{ jsonrpc => '2.0', id => 3, method => 'shutdown' },
        +{ jsonrpc => '2.0', method => 'exit' },
    );

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    ok $comp->{result}{items}, 'has items';

    my @labels = map { $_->{label} } @{$comp->{result}{items}};
    ok((grep { $_ eq 'T' } @labels), 'T in completions');
    ok((grep { $_ eq 'U' } @labels), 'U in completions');
    # Should not include primitives
    ok(!(grep { $_ eq 'Int' } @labels), 'Int not in generic completions');
};

# ── No completion outside type context ───────────

subtest 'no completion outside type context' => sub {
    my $source = "use v5.40;\nmy \$x = ";

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
            method  => 'textDocument/completion',
            params  => +{
                textDocument => +{ uri => 'file:///test.pm' },
                position => +{ line => 1, character => length('my $x = ') },
            },
        },
        +{ jsonrpc => '2.0', id => 3, method => 'shutdown' },
        +{ jsonrpc => '2.0', method => 'exit' },
    );

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    is scalar @{$comp->{result}{items}}, 0, 'no completions outside type context';
};

done_testing;
