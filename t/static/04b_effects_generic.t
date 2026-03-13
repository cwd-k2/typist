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

# ── Bounded generics: extraction ─────────────────

subtest 'Extractor: effect State[S: Num] extracts bound specs' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package BoundedEff;
use v5.40;

effect 'Counter[S: Num]' => +{
    get   => '() -> S',
    add   => '(S) -> Void',
};
PERL

    ok exists $result->{effects}{Counter}, 'Counter extracted';
    my $info = $result->{effects}{Counter};
    is_deeply $info->{type_params}, ['S'], 'type_params = bare names';
    is_deeply $info->{type_param_specs}, ['S: Num'], 'type_param_specs = raw specs';
};

# ── Bounded generics: registration ───────────────

subtest 'Registration: bounded effect generics parsed with parse_generic_decl' => sub {
    require Typist::Static::Registration;
    require Typist::Effect;

    my $registry = Typist::Registry->new;
    require Typist::Prelude;
    Typist::Prelude->install($registry);

    my $extracted = Typist::Static::Extractor->extract(<<'PERL');
package BoundedReg;
use v5.40;

effect 'Counter[S: Num]' => +{
    get   => '() -> S',
    add   => '(S) -> Void',
};
PERL

    Typist::Static::Registration->register_effects($extracted, $registry);

    my $eff = $registry->lookup_effect('Counter');
    ok $eff, 'Counter registered';
    is_deeply [$eff->type_params], ['S'], 'bare type_params in Effect object';

    # Check that the registered operation has structured generics with bound
    my $get_sig = $registry->lookup_function('Counter', 'get');
    ok $get_sig, 'get operation registered';
    my @generics = ($get_sig->{generics} // [])->@*;
    ok @generics, 'generics present on operation';
    is $generics[0]{name}, 'S', 'generic name = S';
    is $generics[0]{bound_expr}, 'Num', 'generic bound_expr = Num';
};

# ── Bounded generics: static analysis ────────────

subtest 'Analyzer: bounded effect param violation detected' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Prelude;
    Typist::Prelude->install($ws_reg);

    require Typist::Effect;
    $ws_reg->register_effect('Counter',
        Typist::Effect->new(
            name        => 'Counter',
            operations  => +{ get => '() -> Int', add => '(Int) -> Void' },
            type_params => ['S'],
        ),
    );

    my $source = <<'PERL';
package BoundedCheck;
use v5.40;

effect 'Counter[S: Num]' => +{
    get   => '() -> S',
    add   => '(S) -> Void',
};

sub good :sig(() -> Int ![Counter[Int]]) () {
    Counter::get();
}

sub bad :sig(() -> Str ![Counter[Str]]) () {
    Counter::get();
}
PERL

    my $result = Typist::Static::Analyzer->analyze($source,
        workspace_registry => $ws_reg,
        file               => '(test)',
    );

    my @diags = $result->{diagnostics}->@*;
    my @bound_errs = grep { ($_->{message} // '') =~ /bound.*Num|Num.*bound/i } @diags;
    ok @bound_errs, 'bound violation for Counter[Str] detected'
        or diag explain \@diags;

    # Counter[Int] should be fine
    my @int_errs = grep { ($_->{message} // '') =~ /Counter\[Int\]/ } @diags;
    is scalar(@int_errs), 0, 'Counter[Int] passes bound check';
};

# ── Bounded generics: typeclass constraint ───────

subtest 'Analyzer: effect with typeclass constraint' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Prelude;
    Typist::Prelude->install($ws_reg);

    # Register Show typeclass and Int instance
    require Typist::TypeClass;
    my $show_def = Typist::TypeClass->new_class(
        name    => 'Show',
        var     => 'T',
        methods => +{ show => '(T) -> Str' },
    );
    $ws_reg->register_typeclass('Show', $show_def);
    $ws_reg->register_instance('Show', 'Int', +{});

    my $source = <<'PERL';
package TcEffect;
use v5.40;

effect 'Logger[S: Show]' => +{
    log_val => '(S) -> Void',
};

sub ok_fn :sig(() -> Void ![Logger[Int]]) () {
    Logger::log_val(42);
}
PERL

    my $result = Typist::Static::Analyzer->analyze($source,
        workspace_registry => $ws_reg,
        file               => '(test)',
    );

    my @diags = $result->{diagnostics}->@*;
    my @tc_errs = grep { ($_->{message} // '') =~ /Show/ } @diags;
    is scalar(@tc_errs), 0, 'Logger[Int] passes Show constraint (Int has Show instance)'
        or diag explain \@diags;
};

# ── Parameterized effect handle discharge ─────────

subtest 'EffectChecker: handle State discharges State[Int]' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Prelude;
    Typist::Prelude->install($ws_reg);

    require Typist::Effect;
    $ws_reg->register_effect('State',
        Typist::Effect->new(
            name        => 'State',
            operations  => +{ get => '() -> Int', put => '(Int) -> Void' },
            type_params => ['S'],
        ),
    );

    my $source = <<'PERL';
package HandleDischarge;
use v5.40;

sub with_state :sig(() -> Int) () {
    handle {
        my $v = State::get();
        $v;
    } State => +{
        get => sub ($resume) { $resume->(42) },
        put => sub ($val, $resume) { $resume->() },
    };
}
PERL

    my $result = Typist::Static::Analyzer->analyze($source,
        workspace_registry => $ws_reg,
        file               => '(test)',
    );

    my @diags = $result->{diagnostics}->@*;
    my @eff_errs = grep { $_->{kind} eq 'EffectMismatch' } @diags;
    is scalar(@eff_errs), 0,
        'handle State => discharges State[Int] labels via label_base_name'
        or diag explain \@eff_errs;
};

done_testing;
