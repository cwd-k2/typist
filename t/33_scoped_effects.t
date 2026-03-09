use v5.40;
use Test::More;

use Typist;

# ── Effect definitions ──────────────────────────

BEGIN {
    effect 'State[S]' => +{
        get => '() -> S',
        put => '(S) -> Void',
    };

    effect Logger => +{
        log => '(Str) -> Void',
    };
}

# ── EffectScope creation ────────────────────────

subtest 'scoped creates blessed EffectScope' => sub {
    my $counter = scoped 'State[Int]';
    ok $counter, 'scoped returns object';
    isa_ok $counter, 'Typist::EffectScope', 'isa EffectScope';
    isa_ok $counter, 'Typist::EffectScope::State', 'isa EffectScope::State';
    is $counter->effect_name, 'State[Int]', 'effect_name';
    is $counter->base_name, 'State', 'base_name';
    ok $counter->_scope_id, 'has unique scope_id';
};

subtest 'two scoped have distinct identities' => sub {
    my $a = scoped 'State[Int]';
    my $b = scoped 'State[Int]';
    isnt $a->_scope_id, $b->_scope_id, 'different scope_ids';
};

# ── Scoped dispatch via handle ──────────────────

subtest 'scoped handler dispatch' => sub {
    my $counter = scoped 'State[Int]';
    my $state = 0;

    my $result = handle {
        $counter->put(42);
        $counter->get();
    } $counter => +{
        get => sub { $state },
        put => sub ($v) { $state = $v },
    };

    is $state, 42, 'put updated state';
    is $result, 42, 'get returned state';
};

subtest 'two independent instances of same effect' => sub {
    my $a = scoped 'State[Int]';
    my $b = scoped 'State[Int]';
    my ($state_a, $state_b) = (0, 0);

    handle {
        handle {
            $a->put(10);
            $b->put(20);
            is $a->get(), 10, 'a is 10';
            is $b->get(), 20, 'b is 20';
        } $b => +{
            get => sub { $state_b },
            put => sub ($v) { $state_b = $v },
        };
    } $a => +{
        get => sub { $state_a },
        put => sub ($v) { $state_a = $v },
    };

    is $state_a, 10, 'state_a independent';
    is $state_b, 20, 'state_b independent';
};

# ── Mixed name-based and scoped dispatch ────────

subtest 'name-based and scoped handlers coexist' => sub {
    my $counter = scoped 'State[Int]';
    my $state = 0;
    my @log;

    handle {
        Logger::log("before");
        $counter->put(99);
        Logger::log("after: " . $counter->get());
    } $counter => +{
        get => sub { $state },
        put => sub ($v) { $state = $v },
    },
    Logger => +{
        log => sub ($msg) { push @log, $msg },
    };

    is $state, 99, 'scoped state updated';
    is_deeply \@log, ['before', 'after: 99'], 'name-based logger works alongside scoped';
};

# ── Exception cleanup for scoped handlers ───────

subtest 'exception cleanup for scoped handlers' => sub {
    my $counter = scoped 'State[Int]';

    eval {
        handle {
            $counter->put(1);
            die "boom\n";
        } $counter => +{
            get => sub { 0 },
            put => sub ($) { },
        };
    };
    like $@, qr/boom/, 'exception propagated';

    # Handler should be cleaned up — no scoped handler available
    eval { $counter->get() };
    like $@, qr/No scoped handler/, 'scoped handler cleaned up after exception';
};

# ── Exn handler with scoped effects ─────────────

subtest 'Exn handler works with scoped effects' => sub {
    my $counter = scoped 'State[Int]';
    my $state = 0;

    my $result = handle {
        $counter->put(5);
        die "caught\n";
    } $counter => +{
        get => sub { $state },
        put => sub ($v) { $state = $v },
    },
    Exn => +{
        throw => sub ($err) { "recovered: $err" },
    };

    is $state, 5, 'state was updated before exception';
    is $result, "recovered: caught\n", 'Exn handler caught the error';
};

# ── No handler error ────────────────────────────

subtest 'scoped without handler dies' => sub {
    my $counter = scoped 'State[Int]';
    eval { $counter->get() };
    like $@, qr/No scoped handler/, 'dies without handle block';
};

subtest 'unknown effect in scoped dies' => sub {
    eval { scoped 'Bogus' };
    like $@, qr/Unknown effect/, 'unknown effect dies';
};

done_testing;
