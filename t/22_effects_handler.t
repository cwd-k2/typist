use v5.40;
use Test::More;

use Typist -runtime;

# ── Register effects at compile time ─────────────

BEGIN {
    effect Console => +{
        log => '(Str) -> Void',
    };

    effect State => +{
        get => '() -> Int',
        put => '(Int) -> Void',
    };
}

# ── Helper: reset handler stack between subtests ──

sub reset_handlers { Typist::Handler->reset }

# ── perform with no handler → die ────────────────

subtest 'perform without handler dies' => sub {
    reset_handlers();

    eval { perform Console => log => "hello" };
    like $@, qr/No handler for effect Console::log/,
        'die message names effect and operation';
};

# ── perform with handler → dispatch ──────────────

subtest 'perform dispatches to registered handler' => sub {
    reset_handlers();

    my @captured;
    Typist::Handler->push_handler('Console', +{
        log => sub ($msg) { push @captured, $msg },
    });

    perform Console => log => "hello";
    perform Console => log => "world";

    is_deeply \@captured, ["hello", "world"],
        'handler receives arguments';

    Typist::Handler->pop_handler;
};

# ── perform returns handler result ───────────────

subtest 'perform returns handler return value' => sub {
    reset_handlers();

    Typist::Handler->push_handler('State', +{
        get => sub { 42 },
        put => sub ($v) { undef },
    });

    my $val = perform State => get =>;
    is $val, 42, 'perform returns handler result';

    Typist::Handler->pop_handler;
};

# ── Nested handlers: inner shadows outer ─────────

subtest 'nested handlers: inner shadows outer' => sub {
    reset_handlers();

    my @outer_log;
    my @inner_log;

    Typist::Handler->push_handler('Console', +{
        log => sub ($msg) { push @outer_log, "outer:$msg" },
    });

    Typist::Handler->push_handler('Console', +{
        log => sub ($msg) { push @inner_log, "inner:$msg" },
    });

    perform Console => log => "test";
    is_deeply \@outer_log, [], 'outer handler not called';
    is_deeply \@inner_log, ["inner:test"], 'inner handler called';

    # Pop inner → outer becomes active
    Typist::Handler->pop_handler;

    perform Console => log => "test2";
    is_deeply \@outer_log, ["outer:test2"], 'outer handler now active';

    Typist::Handler->pop_handler;
};

# ── Multiple effects: independent stacks ─────────

subtest 'multiple effects coexist independently' => sub {
    reset_handlers();

    my @log_out;
    my $state_val = 0;

    Typist::Handler->push_handler('Console', +{
        log => sub ($msg) { push @log_out, $msg },
    });

    Typist::Handler->push_handler('State', +{
        get => sub { $state_val },
        put => sub ($v) { $state_val = $v },
    });

    perform Console => log => "start";
    perform State => put => 10;
    my $v = perform State => get =>;
    perform Console => log => "val=$v";

    is_deeply \@log_out, ["start", "val=10"], 'Console handler works';
    is $state_val, 10, 'State handler works';

    Typist::Handler->pop_handler;
    Typist::Handler->pop_handler;
};

# ── pop_handler removes handler → fallback to die ─

subtest 'pop_handler removes handler' => sub {
    reset_handlers();

    Typist::Handler->push_handler('Console', +{
        log => sub ($msg) { },
    });

    # Works while handler is registered
    eval { perform Console => log => "ok" };
    is $@, '', 'perform succeeds with handler';

    Typist::Handler->pop_handler;

    # After pop, no handler → die
    eval { perform Console => log => "fail" };
    like $@, qr/No handler for effect Console::log/,
        'perform dies after handler removed';
};

# ── Undefined operation → die ────────────────────

subtest 'undefined operation in handler dies' => sub {
    reset_handlers();

    Typist::Handler->push_handler('Console', +{
        log => sub ($msg) { },
        # 'writeLine' not defined in handler
    });

    eval { perform Console => writeLine => "fail" };
    like $@, qr/No handler for effect Console::writeLine/,
        'missing operation in handler raises error';

    Typist::Handler->pop_handler;
};

# ── perform inside annotated function ────────────

sub greet :Type((Str) -> Str !Eff(Console)) ($name) {
    perform Console => log => "Hello, $name!";
    "greeted $name";
}

subtest 'perform inside annotated function' => sub {
    reset_handlers();

    my @log_out;
    Typist::Handler->push_handler('Console', +{
        log => sub ($msg) { push @log_out, $msg },
    });

    my $result = greet("Perl");
    is $result, "greeted Perl", 'function returns correctly';
    is_deeply \@log_out, ["Hello, Perl!"], 'effect performed inside function';

    Typist::Handler->pop_handler;
};

# ── Handler with multiple operations ─────────────

subtest 'handler with multiple operations' => sub {
    reset_handlers();

    my $counter = 0;

    Typist::Handler->push_handler('State', +{
        get => sub { $counter },
        put => sub ($v) { $counter = $v },
    });

    perform State => put => 5;
    is((perform State => get =>), 5, 'get after put');

    perform State => put => (perform State => get =>) + 1;
    is((perform State => get =>), 6, 'increment via get+put');

    Typist::Handler->pop_handler;
};

# ══════════════════════════════════════════════════════
# C-2b: handle block tests
# ══════════════════════════════════════════════════════

# ── Basic handle block: returns body value ──────────

subtest 'handle returns body value' => sub {
    reset_handlers();

    my $result = handle {
        42;
    } Console => +{
        log => sub ($msg) { },
    };

    is $result, 42, 'handle returns body return value';
};

# ── handle dispatches to handler ────────────────────

subtest 'handle dispatches effect operations' => sub {
    reset_handlers();

    my @captured;
    my $result = handle {
        perform Console => log => "hello";
        perform Console => log => "world";
        "done";
    } Console => +{
        log => sub ($msg) { push @captured, $msg },
    };

    is_deeply \@captured, ["hello", "world"],
        'handler received all perform calls';
    is $result, "done", 'body return value propagated';
};

# ── handle pops handlers on normal exit ─────────────

subtest 'handle pops handler after body completes' => sub {
    reset_handlers();

    handle {
        perform Console => log => "inside";
    } Console => +{
        log => sub ($msg) { },
    };

    # After handle returns, handler is gone
    eval { perform Console => log => "outside" };
    like $@, qr/No handler for effect Console::log/,
        'handler is inactive after handle scope';
};

# ── handle pops handlers on exception ───────────────

subtest 'handle pops handler on exception' => sub {
    reset_handlers();

    eval {
        handle {
            perform Console => log => "before die";
            die "boom\n";
        } Console => +{
            log => sub ($msg) { },
        };
    };
    like $@, qr/boom/, 'exception propagated from handle body';

    # Handler must be popped even after exception
    eval { perform Console => log => "after" };
    like $@, qr/No handler for effect Console::log/,
        'handler popped despite exception';
};

# ── Multiple effects simultaneously ─────────────────

subtest 'handle multiple effects simultaneously' => sub {
    reset_handlers();

    my @logs;
    my $result = handle {
        perform Console => log => "start";
        perform State => put => 10;
        my $v = perform State => get =>;
        perform Console => log => "val=$v";
        $v;
    } Console => +{
        log => sub ($msg) { push @logs, $msg },
    }, State => +{
        get => sub { 99 },
        put => sub ($v) { },
    };

    is_deeply \@logs, ["start", "val=99"],
        'Console handler received correct messages';
    is $result, 99, 'State get returned handler value';
};

# ── Nested handle: inner shadows outer ──────────────

subtest 'nested handle: inner shadows outer' => sub {
    reset_handlers();

    my @outer_log;
    my @inner_log;

    my $result = handle {
        perform Console => log => "outer-scope";

        my $inner = handle {
            perform Console => log => "inner-scope";
            "inner-result";
        } Console => +{
            log => sub ($msg) { push @inner_log, $msg },
        };

        # After inner handle returns, outer handler is active again
        perform Console => log => "outer-again";
        $inner;
    } Console => +{
        log => sub ($msg) { push @outer_log, $msg },
    };

    is_deeply \@inner_log, ["inner-scope"],
        'inner handler captured inner perform';
    is_deeply \@outer_log, ["outer-scope", "outer-again"],
        'outer handler captured outer performs';
    is $result, "inner-result",
        'nested handle return value propagated';
};

# ── State effect: full get/put counter example ──────

subtest 'State effect counter via handle' => sub {
    reset_handlers();

    my $state = 0;
    my $result = handle {
        my $n = perform State => get =>;
        perform State => put => $n + 1;
        my $n2 = perform State => get =>;
        perform State => put => $n2 + 1;
        perform State => get =>;
    } State => +{
        get => sub () { $state },
        put => sub ($n) { $state = $n; undef },
    };

    is $result, 2, 'final get returns 2 after two increments';
    is $state, 2, 'state variable was mutated by handler';
};

# ── handle with no perform in body ──────────────────

subtest 'handle with no perform in body' => sub {
    reset_handlers();

    my $result = handle {
        "no effects used";
    } Console => +{
        log => sub ($msg) { die "should not be called" },
    };

    is $result, "no effects used",
        'handle works even when body performs no effects';
};

# ── Multiple effects popped on exception ────────────

subtest 'multiple handlers all popped on exception' => sub {
    reset_handlers();

    eval {
        handle {
            die "multi-boom\n";
        } Console => +{
            log => sub ($msg) { },
        }, State => +{
            get => sub { 0 },
            put => sub ($v) { },
        };
    };
    like $@, qr/multi-boom/, 'exception propagated';

    # Both handlers must be gone
    eval { perform Console => log => "test" };
    like $@, qr/No handler for effect Console::log/,
        'Console handler popped after exception';

    eval { perform State => get => };
    like $@, qr/No handler for effect State::get/,
        'State handler popped after exception';
};

done_testing;
