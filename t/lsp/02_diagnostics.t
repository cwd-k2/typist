use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── didOpen triggers diagnostics ─────────────────

subtest 'didOpen publishes clean diagnostics' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
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
sub bad :Type((T) -> T) ($x) { $x }
PERL

    my $good_source = <<'PERL';
use v5.40;
sub good :Type(<T>(T) -> T) ($x) { $x }
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

# ── Effect mismatch diagnostics via LSP ────────

subtest 'didOpen publishes effect mismatch diagnostics' => sub {
    my $source = <<'PERL';
package EffDemo;
use v5.40;

effect Console => +{};
effect State   => +{};

sub write_msg :Type((Str) -> Str !Eff(Console)) ($s) { $s }

sub stateful :Type((Str) -> Str !Eff(Console | State)) ($x) { $x }

sub caller_fn :Type(() -> Str !Eff(Console)) () {
    stateful("hello");
}

sub pure_fn :Type((Str) -> Str) ($x) {
    write_msg($x);
}

sub helper ($x) { $x }

sub safe_fn :Type((Str) -> Str !Eff(Console)) ($s) {
    helper($s);
}
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{
                uri     => 'file:///test/effects.pm',
                text    => $source,
                version => 1,
            },
        }),
    ));

    my ($diag_notif) = grep { ($_->{method} // '') eq 'textDocument/publishDiagnostics' } @results;
    ok $diag_notif, 'got publishDiagnostics';

    my @eff_diags = grep { $_->{message} =~ /[Ee]ff|unannotated/ }
                    @{$diag_notif->{params}{diagnostics}};

    ok @eff_diags >= 3, 'at least 3 effect diagnostics';

    # Case 1: caller missing callee's effect (State)
    my ($missing) = grep { $_->{message} =~ /State/ } @eff_diags;
    ok $missing, 'missing State effect reported';
    like $missing->{message}, qr/caller_fn.*stateful/, 'identifies caller and callee';

    # Case 2: pure caller calls effectful
    my ($pure) = grep { $_->{message} =~ /no :Eff/ } @eff_diags;
    ok $pure, 'pure-calls-effectful reported';
    like $pure->{message}, qr/pure_fn.*write_msg/, 'identifies pure caller';

    # Case 3: annotated caller calls unannotated
    my ($unann) = grep { $_->{message} =~ /unannotated/ } @eff_diags;
    ok $unann, 'unannotated callee reported';
    like $unann->{message}, qr/safe_fn.*helper/, 'identifies annotated caller and unannotated callee';
};

# ── Diagnostic range has column precision ────────

subtest 'diagnostic range has column precision' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { "not int" }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{
                uri     => 'file:///test/col_precision.pm',
                text    => $source,
                version => 1,
            },
        }),
    ));

    my ($diag_notif) = grep { ($_->{method} // '') eq 'textDocument/publishDiagnostics' } @results;
    ok $diag_notif, 'got publishDiagnostics';

    my @diags = @{$diag_notif->{params}{diagnostics}};
    ok @diags > 0, 'has diagnostics for type mismatch';

    my $d = $diags[0];
    my $range = $d->{range};
    ok $range, 'diagnostic has range';

    # With column precision, start character should not be 0 for errors
    # that occur mid-line, and end character should not be 999
    isnt $range->{end}{character}, 999, 'end character is not hardcoded 999';
};

# ── Diagnostic range falls back gracefully ───────

subtest 'diagnostic range defaults without col info' => sub {
    my $source = <<'PERL';
use v5.40;
typedef CycleX => 'CycleY';
typedef CycleY => 'CycleX';
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{
                uri     => 'file:///test/col_fallback.pm',
                text    => $source,
                version => 1,
            },
        }),
    ));

    my ($diag_notif) = grep { ($_->{method} // '') eq 'textDocument/publishDiagnostics' } @results;
    ok $diag_notif, 'got publishDiagnostics';

    my @diags = @{$diag_notif->{params}{diagnostics}};
    ok @diags > 0, 'has diagnostics';

    my $d = $diags[0];
    my $range = $d->{range};
    ok $range, 'diagnostic has range';

    # Range should be well-formed even without precise col info
    ok $range->{start}{character} >= 0, 'start character >= 0';
    ok $range->{end}{character} > $range->{start}{character}, 'end character > start character';
};

done_testing;
