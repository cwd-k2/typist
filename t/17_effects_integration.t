use v5.40;
use Test::More;

use Typist -runtime;

# ── Register effects at compile time ─────────────

BEGIN {
    effect Console => +{
        readLine  => 'CodeRef[-> Str]',
        writeLine => 'CodeRef[Str -> Void]',
    };

    effect State => +{
        get => 'CodeRef[-> Any]',
        put => 'CodeRef[Any -> Void]',
    };

    effect Log => +{
        log => 'CodeRef[Str -> Void]',
    };
}

# ── Effectful functions ──────────────────────────

sub greet :sig((Str) -> Str ![Console]) ($name) {
    "Hello, $name!";
}

sub main_app :sig(() -> Any ![Console, State]) () {
    greet("world");
    undef;
}

sub logged :sig(<a, r: Row>(Str) -> Str ![Log, r]) ($msg) {
    $msg;
}

sub pure_fn :sig((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

# ── E2E: Runtime behavior is unaffected ─────────

subtest 'effectful functions execute normally' => sub {
    is greet("Perl"), "Hello, Perl!", 'greet works';
    is main_app(), undef, 'main_app returns void';
    is logged("test"), "test", 'logged works';
    is pure_fn(1, 2), 3, 'pure function works';
};

# ── E2E: Type checking still enforced ───────────

subtest 'type checking works alongside effects' => sub {
    eval { greet([1,2,3]) };
    like $@, qr/param 1 expected Str/, 'param types still enforced with effects';
};

subtest 'return type checking works alongside effects' => sub {
    # greet returns Str, so it should enforce
    my $result = greet("ok");
    is $result, "Hello, ok!", 'return type valid';
};

# ── E2E: Effect row registered correctly ────────

subtest 'effect rows stored in Registry' => sub {
    my $sig = Typist::Registry->lookup_function('main', 'greet');
    ok $sig->{effects}, 'greet has effects';
    is $sig->{effects}->to_string, '[Console]', 'single effect';

    $sig = Typist::Registry->lookup_function('main', 'main_app');
    ok $sig, 'main_app sig found';
    is $sig->{effects}->to_string, '[Console, State]', 'multi-effect';

    $sig = Typist::Registry->lookup_function('main', 'logged');
    is $sig->{effects}->to_string, '[Log, r]', 'polymorphic effect';

    $sig = Typist::Registry->lookup_function('main', 'pure_fn');
    ok !$sig->{effects}, 'pure function has no effects';
};

# ── E2E: Subtyping of effect rows ───────────────

subtest 'effect row subtyping' => sub {
    my $cs  = Typist::Type::Row->new(labels => [qw(Console State)]);
    my $c   = Typist::Type::Row->new(labels => [qw(Console)]);
    my $csl = Typist::Type::Row->new(labels => [qw(Console State Log)]);

    ok  Typist::Subtype->is_subtype($cs, $c),    'Console,State <: Console';
    ok  Typist::Subtype->is_subtype($csl, $cs),   'Console,State,Log <: Console,State';
    ok !Typist::Subtype->is_subtype($c, $cs),     'Console </: Console,State';
};

# ── E2E: Row unification ────────────────────────

subtest 'row unification for effect polymorphism' => sub {
    # Simulate: formal = [Log, r], actual = [Console, Log, State]
    my $formal_row = Typist::Type::Row->new(labels => [qw(Log)], row_var => 'r');
    my $actual_row = Typist::Type::Row->new(labels => [qw(Console Log State)]);

    my %bindings;
    Typist::Inference::_unify_rows($formal_row, $actual_row, \%bindings);

    ok exists $bindings{r}, 'r is bound';
    my @bound_labels = sort $bindings{r}->labels;
    is_deeply \@bound_labels, [qw(Console State)], 'r = Console, State';
    ok $bindings{r}->is_closed, 'bound row is closed';

    # Apply substitution to formal
    my $resolved = $formal_row->substitute(\%bindings);
    is_deeply [sort $resolved->labels], [qw(Console Log State)], 'resolved row has all labels';
    ok $resolved->is_closed, 'resolved row is closed';
};

# ── E2E: Kind system ────────────────────────────

subtest 'Row kind in kind system' => sub {
    my $row = Typist::Type::Row->new(labels => [qw(Console)]);
    my $eff = Typist::Type::Eff->new($row);

    ok Typist::KindChecker->infer_kind($row)->equals(Typist::Kind->Row), 'Row has kind Row';
    ok Typist::KindChecker->infer_kind($eff)->equals(Typist::Kind->Row), 'Eff has kind Row';
    ok !Typist::Kind->Row->equals(Typist::Kind->Star), 'Row != Star';
};

# ── E2E: Effect definition ──────────────────────

subtest 'effect definition accessible' => sub {
    my $eff = Typist::Registry->lookup_effect('Console');
    ok $eff, 'Console effect exists';
    is_deeply [sort $eff->op_names], [qw(readLine writeLine)], 'operations';
    is $eff->get_op('readLine'), 'CodeRef[-> Str]', 'operation type';
};

# ── E2E: Static analysis via Analyzer ───────────

subtest 'Analyzer detects effect mismatch' => sub {
    require Typist::Static::Analyzer;

    my $ws_reg = Typist::Registry->new;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{ writeLine => 'CodeRef[Str -> Void]' },
    ));
    $ws_reg->register_effect('DB', Typist::Effect->new(
        name => 'DB', operations => +{},
    ));

    my $result = Typist::Static::Analyzer->analyze(<<'PERL', workspace_registry => $ws_reg);
package IntegTest;
use v5.40;

sub db_op :sig((Str) -> Str ![DB]) ($q) {
    return $q;
}

sub handler :sig(() -> Str ![Console]) () {
    db_op("SELECT 1");
}
PERL

    my @eff = grep { $_->{kind} eq 'EffectMismatch' } @{$result->{diagnostics}};
    ok @eff > 0, 'effect mismatch detected';
    like $eff[0]{message}, qr/DB/, 'reports missing DB effect';
};

done_testing;
