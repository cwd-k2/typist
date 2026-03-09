use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;
use Typist::Static::Extractor;
use Typist::Registry;
use Typist::Effect;

# Helper: set up registry with State effect
sub _make_registry () {
    my $ws_reg = Typist::Registry->new;
    require Typist::Prelude;
    Typist::Prelude->install($ws_reg);

    $ws_reg->register_effect('State',
        Typist::Effect->new(
            name        => 'State',
            operations  => +{ get => '() -> Int', put => '(Int) -> Void' },
            type_params => ['S'],
        ),
    );
    $ws_reg;
}

# ── scoped type inference ────────────────────────

subtest 'scoped: variable type inferred as EffectScope[State]' => sub {
    my $ws_reg = _make_registry();

    my $source = <<'PERL';
package ScopedTest;
use v5.40;

my $counter = scoped('State[Int]');
PERL

    my $result = Typist::Static::Analyzer->analyze($source,
        workspace_registry => $ws_reg,
        file               => '(test)',
    );

    my @log = ($result->{infer_log} // [])->@*;
    my ($entry) = grep { $_->{name} eq '$counter' } @log;
    ok $entry, 'infer_log has $counter entry';
    if ($entry) {
        like $entry->{type}, qr/EffectScope\[State/, 'inferred as EffectScope[State[Int]]';
    }
};

# ── method resolution on EffectScope ─────────────

subtest 'scoped method: $ref->get() return type' => sub {
    my $ws_reg = _make_registry();

    my $source = <<'PERL';
package MethodTest;
use v5.40;

sub use_ref :sig(() -> Int) () {
    my $counter = scoped('State[Int]');
    $counter->get();
}
PERL

    my $result = Typist::Static::Analyzer->analyze($source,
        workspace_registry => $ws_reg,
        file               => '(test)',
    );

    my @diags = $result->{diagnostics}->@*;
    my @type_errors = grep { $_->{kind} =~ /TypeMismatch|ReturnType/ } @diags;
    is scalar(@type_errors), 0, 'no type errors: $ref->get() returns Int matching sig'
        or diag explain \@type_errors;
};

subtest 'scoped method: type mismatch detected' => sub {
    my $ws_reg = _make_registry();

    my $source = <<'PERL';
package MismatchTest;
use v5.40;

sub bad_return :sig(() -> Str) () {
    my $counter = scoped('State[Int]');
    $counter->get();
}
PERL

    my $result = Typist::Static::Analyzer->analyze($source,
        workspace_registry => $ws_reg,
        file               => '(test)',
    );

    my @diags = $result->{diagnostics}->@*;
    my @type_errors = grep { $_->{kind} =~ /TypeMismatch|ReturnType/ } @diags;
    ok scalar(@type_errors) >= 1, 'type mismatch: $ref->get() returns Int but Str expected'
        or diag explain \@diags;
};

# ── no false positives ──────────────────────────

subtest 'scoped: no diagnostics on clean usage' => sub {
    my $ws_reg = _make_registry();

    my $source = <<'PERL';
package CleanTest;
use v5.40;

my $counter = scoped('State[Int]');
PERL

    my $result = Typist::Static::Analyzer->analyze($source,
        workspace_registry => $ws_reg,
        file               => '(test)',
    );

    my @diags = $result->{diagnostics}->@*;
    my @errors = grep { $_->{kind} !~ /ImportHint/ } @diags;
    is scalar(@errors), 0, 'no diagnostics for simple scoped usage'
        or diag explain \@errors;
};

done_testing;
