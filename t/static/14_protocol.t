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

effect DB, [qw(None Connected Authed)] => +{
    connect    => ['(Str) -> Void',      protocol('None -> Connected')],
    auth       => ['(Str, Str) -> Void', protocol('Connected -> Authed')],
    query      => ['(Str) -> Str',       protocol('Authed -> Authed')],
    disconnect => ['() -> Void',         protocol('Connected -> None')],
};

sub setup :Type(() -> Void !Eff(DB<None -> Authed>)) () {
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

effect DB, [qw(None Connected Authed)] => +{
    connect    => ['(Str) -> Void',      protocol('None -> Connected')],
    auth       => ['(Str, Str) -> Void', protocol('Connected -> Authed')],
    query      => ['(Str) -> Str',       protocol('Authed -> Authed')],
    disconnect => ['() -> Void',         protocol('Connected -> None')],
};

sub bad :Type(() -> Void !Eff(DB<None -> Authed>)) () {
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

effect DB, [qw(None Connected Authed)] => +{
    connect    => ['(Str) -> Void',      protocol('None -> Connected')],
    auth       => ['(Str, Str) -> Void', protocol('Connected -> Authed')],
    query      => ['(Str) -> Str',       protocol('Authed -> Authed')],
    disconnect => ['() -> Void',         protocol('Connected -> None')],
};

sub partial :Type(() -> Void !Eff(DB<None -> Authed>)) () {
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

effect DB, [qw(None Connected Authed)] => +{
    connect    => ['(Str) -> Void',      protocol('None -> Connected')],
    auth       => ['(Str, Str) -> Void', protocol('Connected -> Authed')],
    query      => ['(Str) -> Str',       protocol('Authed -> Authed')],
    disconnect => ['() -> Void',         protocol('Connected -> None')],
};

sub query_only :Type((Str) -> Str !Eff(DB<Authed>)) ($sql) {
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

effect DB, [qw(None Connected Authed)] => +{
    connect    => ['(Str) -> Void',      protocol('None -> Connected')],
    auth       => ['(Str, Str) -> Void', protocol('Connected -> Authed')],
    query      => ['(Str) -> Str',       protocol('Authed -> Authed')],
    disconnect => ['() -> Void',         protocol('Connected -> None')],
};

effect IO => +{};

sub mixed :Type(() -> Void !Eff(DB<None -> Connected> | IO)) () {
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

effect BadDB, [qw(None Connected)] => +{
    connect    => ['(Str) -> Void', protocol('None -> Connected')],
    query      => ['(Str) -> Str',  protocol('Connected -> Connected')],
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

effect BadDB2, [qw(None Ghost)] => +{
    connect    => ['(Str) -> Void', protocol('None -> Ghost')],
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

effect BadDB3, [qw(None)] => +{
    connect    => ['(Str) -> Void', protocol('None -> Connected')],
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

effect DB, [qw(None Connected Authed)] => +{
    connect    => ['(Str) -> Void',      protocol('None -> Connected')],
    auth       => ['(Str, Str) -> Void', protocol('Connected -> Authed')],
    query      => ['(Str) -> Str',       protocol('Authed -> Authed')],
    disconnect => ['() -> Void',         protocol('Connected -> None')],
};

sub do_connect :Type(() -> Void !Eff(DB<None -> Connected>)) () {
    DB::connect("localhost");
}

sub full_setup :Type(() -> Void !Eff(DB<None -> Authed>)) () {
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

effect DB, [qw(None Connected Authed)] => +{
    connect    => ['(Str) -> Void',      protocol('None -> Connected')],
    auth       => ['(Str, Str) -> Void', protocol('Connected -> Authed')],
    query      => ['(Str) -> Str',       protocol('Authed -> Authed')],
    disconnect => ['() -> Void',         protocol('Connected -> None')],
};

sub setup :Type(() -> Void !Eff(DB<None -> Authed>)) () {
    DB::connect("localhost");
    DB::auth("user", "pass");
}
PERL

    my $hints = $result->{protocol_hints} // [];
    ok @$hints >= 2, 'at least 2 protocol hints generated';
    is $hints->[0]{label}, 'DB', 'first hint label is DB';
    is $hints->[0]{from}, 'None', 'first hint from state';
    is $hints->[0]{to}, 'Connected', 'first hint to state';
};

done_testing;
