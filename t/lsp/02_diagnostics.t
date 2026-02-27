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

# ── didOpen triggers diagnostics ─────────────────

subtest 'didOpen publishes clean diagnostics' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
sub add :Params(Int, Int) :Returns(Int) ($a, $b) { $a + $b }
PERL

    my @results = run_session(
        { jsonrpc => '2.0', id => 1, method => 'initialize', params => {} },
        { jsonrpc => '2.0', method => 'initialized', params => {} },
        {
            jsonrpc => '2.0',
            method  => 'textDocument/didOpen',
            params  => {
                textDocument => {
                    uri     => 'file:///test/clean.pm',
                    text    => $source,
                    version => 1,
                },
            },
        },
        { jsonrpc => '2.0', id => 2, method => 'shutdown' },
        { jsonrpc => '2.0', method => 'exit' },
    );

    # Find publishDiagnostics notification
    my ($diag_notif) = grep { ($_->{method} // '') eq 'textDocument/publishDiagnostics' } @results;
    ok $diag_notif, 'got publishDiagnostics';
    is $diag_notif->{params}{uri}, 'file:///test/clean.pm', 'correct URI';
    is scalar @{$diag_notif->{params}{diagnostics}}, 0, 'no diagnostics for clean code';
};

# ── didOpen with errors ──────────────────────────

subtest 'didOpen publishes error diagnostics' => sub {
    my $source = <<'PERL';
use v5.40;
typedef CycleA => 'CycleB';
typedef CycleB => 'CycleA';
PERL

    my @results = run_session(
        { jsonrpc => '2.0', id => 1, method => 'initialize', params => {} },
        { jsonrpc => '2.0', method => 'initialized', params => {} },
        {
            jsonrpc => '2.0',
            method  => 'textDocument/didOpen',
            params  => {
                textDocument => {
                    uri     => 'file:///test/bad.pm',
                    text    => $source,
                    version => 1,
                },
            },
        },
        { jsonrpc => '2.0', id => 2, method => 'shutdown' },
        { jsonrpc => '2.0', method => 'exit' },
    );

    my ($diag_notif) = grep { ($_->{method} // '') eq 'textDocument/publishDiagnostics' } @results;
    ok $diag_notif, 'got publishDiagnostics';
    ok scalar @{$diag_notif->{params}{diagnostics}} > 0, 'has error diagnostics';

    my $first = $diag_notif->{params}{diagnostics}[0];
    ok $first->{range}, 'diagnostic has range';
    is $first->{source}, 'typist', 'source is typist';
    like $first->{message}, qr/cycle/i, 'message mentions cycle';
};

# ── didChange triggers re-analysis ───────────────

subtest 'didChange updates diagnostics' => sub {
    my $bad_source = <<'PERL';
use v5.40;
sub bad :Params(T) :Returns(T) ($x) { $x }
PERL

    my $good_source = <<'PERL';
use v5.40;
sub good :Generic(T) :Params(T) :Returns(T) ($x) { $x }
PERL

    my @results = run_session(
        { jsonrpc => '2.0', id => 1, method => 'initialize', params => {} },
        { jsonrpc => '2.0', method => 'initialized', params => {} },
        {
            jsonrpc => '2.0',
            method  => 'textDocument/didOpen',
            params  => {
                textDocument => { uri => 'file:///test/edit.pm', text => $bad_source, version => 1 },
            },
        },
        {
            jsonrpc => '2.0',
            method  => 'textDocument/didChange',
            params  => {
                textDocument => { uri => 'file:///test/edit.pm', version => 2 },
                contentChanges => [{ text => $good_source }],
            },
        },
        { jsonrpc => '2.0', id => 2, method => 'shutdown' },
        { jsonrpc => '2.0', method => 'exit' },
    );

    # Should have two publishDiagnostics: one with errors, one clean
    my @diags = grep { ($_->{method} // '') eq 'textDocument/publishDiagnostics' } @results;
    is scalar @diags, 2, 'two diagnostic publications';

    # First should have errors
    ok scalar @{$diags[0]->{params}{diagnostics}} > 0, 'first has errors';

    # Second should be clean
    is scalar @{$diags[1]->{params}{diagnostics}}, 0, 'second is clean after fix';
};

done_testing;
