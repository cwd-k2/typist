use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;
use Typist::Static::Extractor;
use Typist::Registry;

# ── Extractor: parameterized effect definition ───

subtest 'Extractor: effect State[S]' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package GenEff;
use v5.40;

effect 'State[S]' => +{
    get => '() -> S',
    put => '(S) -> Void',
};
PERL

    ok exists $result->{effects}{State}, 'State extracted (base name)';
    my $info = $result->{effects}{State};
    is_deeply $info->{type_params}, ['S'], 'type_params = [S]';
    is $info->{operations}{get}, '() -> S', 'get sig';
    is $info->{operations}{put}, '(S) -> Void', 'put sig';
};

subtest 'Extractor: effect with multiple type params' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package MultiParam;
use v5.40;

effect 'Reader[R, W]' => +{
    ask  => '() -> R',
    tell => '(W) -> Void',
};
PERL

    ok exists $result->{effects}{Reader}, 'Reader extracted';
    is_deeply $result->{effects}{Reader}{type_params}, ['R', 'W'], 'two type params';
};

subtest 'Extractor: non-parameterized effect has no type_params' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package Plain;
use v5.40;

effect Console => +{
    log => '(Str) -> Void',
};
PERL

    ok exists $result->{effects}{Console}, 'Console extracted';
    ok !$result->{effects}{Console}{type_params}, 'no type_params';
};

# ── Analyzer: parameterized effect labels ────────

subtest 'Analyzer: ![State[Int]] matches declared ![State[Int]]' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Prelude;
    Typist::Prelude->install($ws_reg);

    # Register State effect
    require Typist::Effect;
    $ws_reg->register_effect('State',
        Typist::Effect->new(
            name        => 'State',
            operations  => +{ get => '() -> Int', put => '(Int) -> Void' },
            type_params => ['S'],
        ),
    );

    my $source = <<'PERL';
package StateTest;
use v5.40;

sub get_state :sig(() -> Int ![State[Int]]) () {
    State::get();
}
PERL

    my $result = Typist::Static::Analyzer->analyze($source,
        workspace_registry => $ws_reg,
        file               => '(test)',
    );

    my @diags = $result->{diagnostics}->@*;
    my @eff_diags = grep { $_->{kind} =~ /Effect|Unknown/ } @diags;
    is scalar(@eff_diags), 0, 'no effect diagnostics for matching State[Int]'
        or diag explain \@eff_diags;
};

subtest 'Checker: parameterized label passes is_effect_label' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Prelude;
    Typist::Prelude->install($ws_reg);
    require Typist::Effect;

    $ws_reg->register_effect('State',
        Typist::Effect->new(
            name        => 'State',
            operations  => +{ get => '() -> Int' },
            type_params => ['S'],
        ),
    );

    my $source = <<'PERL';
package CheckerTest;
use v5.40;

sub read_state :sig(() -> Int ![State[Int]]) () { 1 }
PERL

    my $result = Typist::Static::Analyzer->analyze($source,
        workspace_registry => $ws_reg,
        file               => '(test)',
    );

    my @diags = $result->{diagnostics}->@*;
    my @unknown = grep { $_->{kind} eq 'UnknownEffect' } @diags;
    is scalar(@unknown), 0, 'State[Int] is not flagged as UnknownEffect'
        or diag explain \@unknown;
};

subtest 'Checker: truly unknown parameterized effect is flagged' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Prelude;
    Typist::Prelude->install($ws_reg);

    my $source = <<'PERL';
package UnknownTest;
use v5.40;

sub bad :sig(() -> Int ![Bogus[Int]]) () { 1 }
PERL

    my $result = Typist::Static::Analyzer->analyze($source,
        workspace_registry => $ws_reg,
        file               => '(test)',
    );

    my @diags = $result->{diagnostics}->@*;
    my @unknown = grep { $_->{kind} eq 'UnknownEffect' } @diags;
    ok scalar(@unknown) >= 1, 'Bogus[Int] flagged as UnknownEffect'
        or diag explain \@diags;
};

subtest 'Registration: type_params passed through to Effect' => sub {
    require Typist::Static::Registration;
    require Typist::Effect;

    my $registry = Typist::Registry->new;
    require Typist::Prelude;
    Typist::Prelude->install($registry);

    my $extracted = Typist::Static::Extractor->extract(<<'PERL');
package RegTest;
use v5.40;

effect 'State[S]' => +{
    get => '() -> S',
    put => '(S) -> Void',
};
PERL

    Typist::Static::Registration->register_effects($extracted, $registry);

    my $eff = $registry->lookup_effect('State');
    ok $eff, 'State registered in registry';
    is_deeply [$eff->type_params], ['S'], 'type_params preserved through Registration';
    ok $eff->is_generic, 'is_generic';
};

done_testing;
