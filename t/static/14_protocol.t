use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;
use Typist::Static::Extractor;
use Typist::Registry;
use Typist::Effect;
use Typist::Protocol;

# Helper: create workspace registry with a protocol-enabled effect
sub _ws_registry_with_db {
    my $ws = Typist::Registry->new;
    my $protocol = Typist::Protocol->new(transitions => +{
        None      => +{ connect => 'Connected' },
        Connected => +{ auth => 'Authed', disconnect => 'None' },
        Authed    => +{ query => 'Authed', disconnect => 'None' },
    });
    $ws->register_effect('DB', Typist::Effect->new(
        name       => 'DB',
        operations => +{
            connect    => '(Str) -> Void',
            auth       => '(Str, Str) -> Void',
            query      => '(Str) -> Str',
            disconnect => '() -> Void',
        },
        protocol => $protocol,
    ));
    $ws;
}

# ── Clean: correct operation order ────────────

subtest 'clean — correct protocol sequence' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoClean;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub setup :sig(() -> Void ![DB<None -> Authed>]) () {
    DB::connect("localhost");
    DB::auth("user", "pass");
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'correct sequence produces no ProtocolMismatch';
};

# ── Error: operation in wrong state ──────────

subtest 'error — operation disallowed in current state' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoBadOp;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub bad :sig(() -> Void ![DB<None -> Authed>]) () {
    DB::query("SELECT 1");
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'disallowed operation produces ProtocolMismatch';
    like $errors[0]{message}, qr/query.*not allowed.*None/, 'message mentions op and state';
};

# ── Error: wrong end state ────────────────────

subtest 'error — end state mismatch' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoEndState;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub partial :sig(() -> Void ![DB<None -> Authed>]) () {
    DB::connect("localhost");
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'wrong end state produces ProtocolMismatch';
    like $errors[0]{message}, qr/ends in state.*Connected.*declared.*Authed/, 'message mentions end state mismatch';
};

# ── Clean: invariant state DB<Authed> ────────

subtest 'clean — invariant state annotation' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoInvariant;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub query_only :sig((Str) -> Str ![DB<Authed>]) ($sql) {
    DB::query($sql);
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'invariant state with valid op produces no error';
};

# ── Clean: protocol-less IO mixed with protocol DB ──

subtest 'clean — mixed protocol/non-protocol effects' => sub {
    my $ws = _ws_registry_with_db();
    $ws->register_effect('IO', Typist::Effect->new(name => 'IO', operations => +{}));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws);
package ProtoMixed;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

effect IO => +{};

sub mixed :sig(() -> Void ![DB<None -> Connected>, IO]) () {
    DB::connect("localhost");
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'mixed protocol/non-protocol effects works';
};

# ── Well-formedness: unreachable operation ────

subtest 'well-formedness — unreachable operation' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoUnreachable;
use v5.40;

effect BadDB => qw/None Connected/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    query      => protocol('(Str) -> Str', 'Connected -> Connected'),
    orphan_op  => '() -> Void',
};
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'unreachable op produces ProtocolMismatch';
    like $errors[0]{message}, qr/orphan_op.*unreachable/, 'message mentions unreachable op';
};

# ── Well-formedness: undefined target state ────

subtest 'well-formedness — undefined transition target' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoUndefined;
use v5.40;

effect BadDB2 => qw/None Ghost/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Ghost'),
};
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    # Ghost is now in the states list and also a target, so no "undefined state" error
    is scalar @errors, 0, 'Ghost is declared in states list — no error';
};

# ── Well-formedness: undeclared state in transitions ────

subtest 'well-formedness — state not in declared states list' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoMissing;
use v5.40;

effect BadDB3 => qw/None/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
};
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'undeclared state produces ProtocolMismatch';
    like $errors[0]{message}, qr/Connected.*not in the declared states/, 'message mentions undeclared state';
};

# ── Function call protocol composition ────────

subtest 'clean — function call protocol composition' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoCompose;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub do_connect :sig(() -> Void ![DB<None -> Connected>]) () {
    DB::connect("localhost");
}

sub full_setup :sig(() -> Void ![DB<None -> Authed>]) () {
    do_connect();
    DB::auth("user", "pass");
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'function call composition works';
};

# ── Protocol hints are generated ──────────────

subtest 'protocol hints generated' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoHints;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub setup :sig(() -> Void ![DB<None -> Authed>]) () {
    DB::connect("localhost");
    DB::auth("user", "pass");
}
PERL

    my $hints = $result->{protocol_hints} // [];
    ok @$hints >= 2, 'at least 2 protocol hints generated';
    is $hints->[0]{label}, 'DB', 'first hint label is DB';
    is_deeply $hints->[0]{from}, ['None'], 'first hint from state';
    is_deeply $hints->[0]{to}, ['Connected'], 'first hint to state';
};

# ── Branching: convergent if/else ─────────────

subtest 'branching — convergent if/else (same transition both branches)' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoBranch1;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub setup :sig((Bool) -> Void ![DB<None -> Connected>]) ($flag) {
    if ($flag) {
        DB::connect("host1");
    } else {
        DB::connect("host2");
    }
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'convergent if/else produces no error';
};

# ── Branching: divergent if/else ──────────────

subtest 'branching — divergent if/else (different end states)' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoBranch2;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub bad_branch :sig((Bool) -> Void ![DB<None -> Authed>]) ($flag) {
    DB::connect("localhost");
    if ($flag) {
        DB::auth("user", "pass");
    } else {
        DB::disconnect();
    }
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'divergent if/else produces ProtocolMismatch';
    like $errors[0]{message}, qr/ends in state/, 'message mentions end state mismatch (union)';
};

# ── Branching: one branch returns ─────────────

subtest 'branching — one branch returns, other continues' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoBranch3;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub early_return :sig((Bool) -> Void ![DB<None -> Authed>]) ($flag) {
    DB::connect("localhost");
    if ($flag) {
        return;
    } else {
        DB::auth("user", "pass");
    }
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'return branch excluded, else branch reaches declared end state';
};

# ── Branching: all branches return ────────────

subtest 'branching — all branches return (no final state check)' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoBranch4;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub all_return :sig((Bool) -> Void ![DB<None -> Authed>]) ($flag) {
    DB::connect("localhost");
    if ($flag) {
        DB::auth("user", "pass");
        return;
    } else {
        DB::auth("admin", "admin");
        return;
    }
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'all branches return — no final state check';
};

# ── Branching: if without else (state change) ─

subtest 'branching — if without else (state changes in then block)' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoBranch5;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub maybe_connect :sig((Bool) -> Void ![DB<None -> Connected>]) ($flag) {
    if ($flag) {
        DB::connect("localhost");
    }
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'if without else with state change produces error';
    like $errors[0]{message}, qr/ends in state/, 'message mentions end state mismatch (union)';
};

# ── Branching: if without else (no state change) ─

subtest 'branching — if without else (no state change in then block)' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoBranch6;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub query_loop :sig((Bool) -> Void ![DB<Authed>]) ($flag) {
    if ($flag) {
        DB::query("SELECT 1");
    }
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'if without else, no state change → convergent';
};

# ── Branching: nested if/else ──────────────────

subtest 'branching — nested if/else convergence' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoNested;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub nested :sig((Bool, Bool) -> Void ![DB<None -> Authed>]) ($a, $b) {
    if ($a) {
        DB::connect("host1");
        if ($b) {
            DB::auth("user", "pass");
        } else {
            DB::auth("admin", "admin");
        }
    } else {
        DB::connect("host2");
        DB::auth("guest", "guest");
    }
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'nested if/else converges correctly';
};

# ── Loop: idempotent operation (OK) ───────────

subtest 'loop — idempotent operation in while loop' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoLoop1;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub query_loop :sig(() -> Void ![DB<Authed>]) () {
    while (1) {
        DB::query("SELECT 1");
    }
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'idempotent loop (Authed → Authed) produces no error';
};

# ── Loop: state-changing operation (error) ────

subtest 'loop — state-changing operation in for loop' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoLoop2;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub bad_loop :sig(() -> Void ![DB<Connected>]) () {
    for my $i (1..3) {
        DB::disconnect();
    }
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'state-changing loop produces ProtocolMismatch';
    like $errors[0]{message}, qr/loop body changes state/, 'error mentions loop body';
};

# ── Loop: empty body (OK) ────────────────────

subtest 'loop — empty body is idempotent' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoLoop3;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub noop_loop :sig(() -> Void ![DB<Authed>]) () {
    for my $i (1..3) {
        # no protocol operations
    }
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'empty loop body is idempotent — no error';
};

# ── handle: protocol operations inside handle body ──

subtest 'handle — protocol ops inside handle body traced' => sub {
    my $ws = _ws_registry_with_db();
    $ws->register_effect('Logger', Typist::Effect->new(name => 'Logger', operations => +{
        log => '(Str) -> Void',
    }));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws);
package ProtoHandle1;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

effect Logger => +{ log => '(Str) -> Void' };

sub with_logging :sig(() -> Void ![DB<None -> Authed>, Logger]) () {
    handle {
        DB::connect("localhost");
        DB::auth("user", "pass");
    } Logger => +{ log => sub ($msg) { } };
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'protocol operations inside handle body correctly traced';
};

subtest 'handle — wrong protocol ops inside handle body detected' => sub {
    my $ws = _ws_registry_with_db();
    $ws->register_effect('Logger', Typist::Effect->new(name => 'Logger', operations => +{
        log => '(Str) -> Void',
    }));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws);
package ProtoHandle2;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

effect Logger => +{ log => '(Str) -> Void' };

sub bad_handle :sig(() -> Void ![DB<None -> Authed>, Logger]) () {
    handle {
        DB::query("SELECT 1");
    } Logger => +{ log => sub ($msg) { } };
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'wrong protocol op inside handle body detected';
};

# ── match: protocol operations inside match arms ──

subtest 'match — protocol ops inside match arms traced' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoMatch1;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub match_ops :sig((Str) -> Void ![DB<Connected -> Authed>]) ($mode) {
    match $mode,
        admin => sub { DB::auth("admin", "secret") },
        user  => sub { DB::auth("user", "pass") };
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'convergent match arms produce no error';
};

subtest 'match — divergent match arms detected' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => _ws_registry_with_db());
package ProtoMatch2;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

sub bad_match :sig((Str) -> Void ![DB<Connected -> Authed>]) ($mode) {
    match $mode,
        admin => sub { DB::auth("admin", "secret") },
        guest => sub { DB::disconnect() };
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'divergent match arms produce ProtocolMismatch';
    like $errors[0]{message}, qr/ends in state/, 'error mentions end state mismatch (union)';
};

# ══ Superposition / * state ═══════════════════════

# Helper: workspace registry with a protocol that includes * transitions
sub _ws_registry_with_resettable_db {
    my $ws = Typist::Registry->new;
    my $protocol = Typist::Protocol->new(
        transitions => +{
            None      => +{ connect => 'Connected' },
            Connected => +{ auth => 'Authed', disconnect => 'None' },
            Authed    => +{ query => 'Authed', disconnect => 'None' },
        },
        op_map => +{
            connect    => { from => ['None'],               to => ['Connected'] },
            auth       => { from => ['Connected'],          to => ['Authed'] },
            query      => { from => ['Authed'],             to => ['Authed'] },
            disconnect => { from => ['Authed', 'Connected'], to => ['None'] },
        },
    );
    $ws->register_effect('DB', Typist::Effect->new(
        name       => 'DB',
        operations => +{
            connect    => '(Str) -> Void',
            auth       => '(Str, Str) -> Void',
            query      => '(Str) -> Str',
            disconnect => '() -> Void',
        },
        protocol => $protocol,
    ));
    $ws;
}

subtest 'superposition — branch union converges with subsequent op' => sub {
    my $ws = _ws_registry_with_resettable_db();
    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws);
package ProtoSuperposition1;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Authed | Connected -> None'),
};

sub diverge_then_disconnect :sig((Bool) -> Void ![DB<None -> None>]) ($flag) {
    DB::connect("localhost");
    if ($flag) {
        DB::auth("user", "pass");
    }
    DB::disconnect();
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'branch union {Authed|Connected} matches disconnect from-set';
};

subtest 'ground — * -> * with * in transitions (full cycle)' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoGround1;
use v5.40;

effect DB => qw/Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', '* -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected | Authed -> *'),
};

sub full_cycle :sig(() -> Void ![DB<* -> *>]) () {
    DB::connect("localhost");
    DB::auth("user", "pass");
    DB::query("SELECT 1");
    DB::disconnect();
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, '* -> * full cycle with * in transitions';
};

subtest 'ground — * -> * incomplete cycle errors' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoGround2;
use v5.40;

effect DB => qw/Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', '* -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    disconnect => protocol('() -> Void', 'Connected | Authed -> *'),
};

sub incomplete :sig(() -> Void ![DB<* -> *>]) () {
    DB::connect("localhost");
    DB::auth("user", "pass");
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'incomplete cycle: ends at Authed, not *';
    like $errors[0]{message}, qr/ends in state 'Authed'/, 'error mentions actual end state';
};

subtest 'handle — auto * -> * with * in transitions' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoHandleAuto;
use v5.40;

effect DB => qw/Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', '* -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected | Authed -> *'),
};

sub with_handle :sig(() -> Void ![DB<* -> *>]) () {
    handle {
        DB::connect("localhost");
        DB::auth("user", "pass");
        DB::query("SELECT 1");
        DB::disconnect();
    } DB => +{
        connect    => sub ($host) { },
        auth       => sub ($u, $p) { },
        query      => sub ($sql) { "mock" },
        disconnect => sub () { },
    };
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'handle body: * -> Connected -> Authed -> * (complete cycle)';
};

subtest 'handle — auto * -> * incomplete cycle errors' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoHandleAutoErr;
use v5.40;

effect DB => qw/Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', '* -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    disconnect => protocol('() -> Void', 'Connected | Authed -> *'),
};

sub incomplete_handle :sig(() -> Void ![DB<* -> *>]) () {
    handle {
        DB::connect("localhost");
        DB::auth("user", "pass");
    } DB => +{
        connect    => sub ($host) { },
        auth       => sub ($u, $p) { },
        disconnect => sub () { },
    };
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'handle body incomplete: ends at Authed, not *';
    like $errors[0]{message}, qr/handle body must end at '\*'/, 'error mentions * end state';
};

subtest 'handle — transparent when capturing different effect' => sub {
    my $ws = _ws_registry_with_db();
    $ws->register_effect('Logger', Typist::Effect->new(name => 'Logger', operations => +{
        log => '(Str) -> Void',
    }));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws);
package ProtoHandleTransparent;
use v5.40;

effect DB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected -> None'),
};

effect Logger => +{ log => '(Str) -> Void' };

sub transparent_handle :sig(() -> Void ![DB<None -> Authed>, Logger]) () {
    handle {
        DB::connect("localhost");
        DB::auth("user", "pass");
    } Logger => +{ log => sub ($msg) { } };
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'handle of different effect is transparent to protocol';
};

# ══ Default * -> * for ![DB] without state annotation ═══

subtest 'default — ![DB] without state annotation defaults to * -> *' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoDefault1;
use v5.40;

effect DB => qw/Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', '* -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected | Authed -> *'),
};

sub full_cycle :sig(() -> Void ![DB]) () {
    DB::connect("localhost");
    DB::auth("user", "pass");
    DB::query("SELECT 1");
    DB::disconnect();
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, '![DB] defaults to * -> * — full cycle passes';
};

subtest 'default — ![DB] incomplete cycle errors' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoDefault2;
use v5.40;

effect DB => qw/Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', '* -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    disconnect => protocol('() -> Void', 'Connected | Authed -> *'),
};

sub incomplete :sig(() -> Void ![DB]) () {
    DB::connect("localhost");
    DB::auth("user", "pass");
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, '![DB] incomplete cycle: ends at Authed, not *';
    like $errors[0]{message}, qr/ends in state 'Authed'/, 'error mentions actual end state';
};

# ══ Handle-driven verification ═══════════════════

subtest 'handle-driven — unannotated function with handle block verified' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoHandleDriven1;
use v5.40;

effect DB => qw/Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', '* -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    query      => protocol('(Str) -> Str', 'Authed -> Authed'),
    disconnect => protocol('() -> Void', 'Connected | Authed -> *'),
};

sub run () {
    handle {
        DB::connect("localhost");
        DB::auth("user", "pass");
        DB::query("SELECT 1");
        DB::disconnect();
    } DB => +{
        connect    => sub ($host) { },
        auth       => sub ($u, $p) { },
        query      => sub ($sql) { "mock" },
        disconnect => sub () { },
    };
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'handle-driven: complete cycle passes without annotation';
};

subtest 'handle-driven — unannotated function with incomplete handle errors' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoHandleDriven2;
use v5.40;

effect DB => qw/Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', '* -> Connected'),
    auth       => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
    disconnect => protocol('() -> Void', 'Connected | Authed -> *'),
};

sub run () {
    handle {
        DB::connect("localhost");
        DB::auth("user", "pass");
    } DB => +{
        connect    => sub ($host) { },
        auth       => sub ($u, $p) { },
        disconnect => sub () { },
    };
}
PERL

    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    ok @errors > 0, 'handle-driven: incomplete cycle detected without annotation';
};

subtest 'extraction — protocol(\'A | B -> C\') syntax' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package ProtoExtractSet;
use v5.40;

effect MultiDB => qw/None Connected Authed/ => +{
    connect    => protocol('(Str) -> Void', 'None -> Connected'),
    disconnect => protocol('() -> Void', 'Authed | Connected -> None'),
};
PERL

    # Should extract cleanly without errors
    my @errors = grep { $_->{kind} eq 'ProtocolMismatch' } $result->{diagnostics}->@*;
    is scalar @errors, 0, 'set syntax in protocol() extracted cleanly';
};

done_testing;
