use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── didOpen triggers diagnostics ─────────────────

subtest 'didOpen publishes clean diagnostics' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
sub add :Params(Int, Int) :Returns(Int) ($a, $b) { $a + $b }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{
                uri     => 'file:///test/clean.pm',
                text    => $source,
                version => 1,
            },
        }),
    ));

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

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{
                uri     => 'file:///test/bad.pm',
                text    => $source,
                version => 1,
            },
        }),
    ));

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

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test/edit.pm', text => $bad_source, version => 1 },
        }),
        lsp_notification('textDocument/didChange', +{
            textDocument   => +{ uri => 'file:///test/edit.pm', version => 2 },
            contentChanges => [+{ text => $good_source }],
        }),
    ));

    # Should have two publishDiagnostics: one with errors, one clean
    my @diags = grep { ($_->{method} // '') eq 'textDocument/publishDiagnostics' } @results;
    is scalar @diags, 2, 'two diagnostic publications';

    # First should have errors
    ok scalar @{$diags[0]->{params}{diagnostics}} > 0, 'first has errors';

    # Second should be clean
    is scalar @{$diags[1]->{params}{diagnostics}}, 0, 'second is clean after fix';
};

done_testing;
