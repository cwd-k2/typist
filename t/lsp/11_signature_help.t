use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Signature help on first parameter ──────────

subtest 'signatureHelp shows function signature at open paren' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
add(
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/signatureHelp', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 4 },  # after 'add('
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got signatureHelp response';
    ok $resp->{result}, 'has result';
    my $sigs = $resp->{result}{signatures};
    ok $sigs && @$sigs, 'has signatures';
    like $sigs->[0]{label}, qr/add\(Int, Int\) -> Int/, 'label shows full signature';
    is scalar @{$sigs->[0]{parameters}}, 2, 'two parameters';
    is $resp->{result}{activeParameter}, 0, 'active parameter is 0 (first)';
};

# ── Signature help on second parameter ──────────

subtest 'signatureHelp highlights second parameter after comma' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
add(1,
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/signatureHelp', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 6 },  # after 'add(1, '
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got signatureHelp response';
    is $resp->{result}{activeParameter}, 1, 'active parameter is 1 (second)';
};

# ── Signature help returns null for non-function ─

subtest 'signatureHelp returns null outside function call' => sub {
    my $source = <<'PERL';
use v5.40;
my $x = 42;
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/signatureHelp', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 10 },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got signatureHelp response';
    ok !$resp->{result}, 'result is null outside function call';
};

done_testing;
