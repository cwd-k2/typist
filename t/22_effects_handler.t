use v5.40;
use Test::More;

use Typist -runtime;

# ── Register effects at compile time ─────────────

BEGIN {
    effect Console => +{
        log       => '(Str) -> Void',
        writeLine => '(Str) -> Void',
    };

    effect State => +{
        get => '() -> Int',
        put => '(Int) -> Void',
    };
}

# ── Helper: reset handler stack between subtests ──

sub reset_handlers { Typist::Handler->reset }

# ── Effect::op with no handler → die ────────────────

subtest 'Effect::op without handler dies' => sub {
    reset_handlers();

    eval { Console::log("hello") };
    like $@, qr/No handler for effect Console::log/,
        'die message names effect and operation';
};

# ── Effect::op with handler → dispatch ──────────────

subtest 'Effect::op dispatches to registered handler' => sub {
    reset_handlers();

    my @captured;
    Typist::Handler->push_handler('Console', +{
        log => sub ($msg) { push @captured, $msg },
    });

    Console::log("hello");
    Console::log("world");

    is_deeply \@captured, ["hello", "world"],
        'handler receives arguments';

    Typist::Handler->pop_handler;
};

# ── Effect::op returns handler result ───────────────

subtest 'Effect::op returns handler return value' => sub {
    reset_handlers();

    Typist::Handler->push_handler('State', +{
        get => sub { 42 },
        put => sub ($v) { undef },
    });

    my $val = State::get();
    is $val, 42, 'Effect::op returns handler result';

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

    Console::log("test");
    is_deeply \@outer_log, [], 'outer handler not called';
    is_deeply \@inner_log, ["inner:test"], 'inner handler called';

    # Pop inner → outer becomes active
    Typist::Handler->pop_handler;

    Console::log("test2");
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

    Console::log("start");
    State::put(10);
    my $v = State::get();
    Console::log("val=$v");

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
    eval { Console::log("ok") };
    is $@, '', 'Effect::op succeeds with handler';

    Typist::Handler->pop_handler;

    # After pop, no handler → die
    eval { Console::log("fail") };
    like $@, qr/No handler for effect Console::log/,
        'Effect::op dies after handler removed';
};

# ── Undefined operation → die ────────────────────

subtest 'undefined operation in handler dies' => sub {
    reset_handlers();

    Typist::Handler->push_handler('Console', +{
        log => sub ($msg) { },
        # 'writeLine' not defined in handler
    });

    eval { Console::writeLine("fail") };
    like $@, qr/No handler for effect Console::writeLine/,
        'missing operation in handler raises error';

    Typist::Handler->pop_handler;
};

# ── Effect::op inside annotated function ────────────

sub greet :sig((Str) -> Str ![Console]) ($name) {
    Console::log("Hello, $name!");
    "greeted $name";
}

subtest 'Effect::op inside annotated function' => sub {
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

    State::put(5);
    is(State::get(), 5, 'get after put');

    State::put(State::get() + 1);
    is(State::get(), 6, 'increment via get+put');

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
        Console::log("hello");
        Console::log("world");
        "done";
    } Console => +{
        log => sub ($msg) { push @captured, $msg },
    };

    is_deeply \@captured, ["hello", "world"],
        'handler received all Effect::op calls';
    is $result, "done", 'body return value propagated';
};

# ── handle pops handlers on normal exit ─────────────

subtest 'handle pops handler after body completes' => sub {
    reset_handlers();

    handle {
        Console::log("inside");
    } Console => +{
        log => sub ($msg) { },
    };

    # After handle returns, handler is gone
    eval { Console::log("outside") };
    like $@, qr/No handler for effect Console::log/,
        'handler is inactive after handle scope';
};

# ── handle pops handlers on exception ───────────────

subtest 'handle pops handler on exception' => sub {
    reset_handlers();

    eval {
        handle {
            Console::log("before die");
            die "boom\n";
        } Console => +{
            log => sub ($msg) { },
        };
    };
    like $@, qr/boom/, 'exception propagated from handle body';

    # Handler must be popped even after exception
    eval { Console::log("after") };
    like $@, qr/No handler for effect Console::log/,
        'handler popped despite exception';
};

# ── Multiple effects simultaneously ─────────────────

subtest 'handle multiple effects simultaneously' => sub {
    reset_handlers();

    my @logs;
    my $result = handle {
        Console::log("start");
        State::put(10);
        my $v = State::get();
        Console::log("val=$v");
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
        Console::log("outer-scope");

        my $inner = handle {
            Console::log("inner-scope");
            "inner-result";
        } Console => +{
            log => sub ($msg) { push @inner_log, $msg },
        };

        # After inner handle returns, outer handler is active again
        Console::log("outer-again");
        $inner;
    } Console => +{
        log => sub ($msg) { push @outer_log, $msg },
    };

    is_deeply \@inner_log, ["inner-scope"],
        'inner handler captured inner Effect::op';
    is_deeply \@outer_log, ["outer-scope", "outer-again"],
        'outer handler captured outer calls';
    is $result, "inner-result",
        'nested handle return value propagated';
};

# ── State effect: full get/put counter example ──────

subtest 'State effect counter via handle' => sub {
    reset_handlers();

    my $state = 0;
    my $result = handle {
        my $n = State::get();
        State::put($n + 1);
        my $n2 = State::get();
        State::put($n2 + 1);
        State::get();
    } State => +{
        get => sub () { $state },
        put => sub ($n) { $state = $n; undef },
    };

    is $result, 2, 'final get returns 2 after two increments';
    is $state, 2, 'state variable was mutated by handler';
};

# ── handle with no Effect::op in body ──────────────────

subtest 'handle with no Effect::op in body' => sub {
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
    eval { Console::log("test") };
    like $@, qr/No handler for effect Console::log/,
        'Console handler popped after exception';

    eval { State::get() };
    like $@, qr/No handler for effect State::get/,
        'State handler popped after exception';
};

# ══════════════════════════════════════════════════════
# Exn handling: die / Exn::throw bridged to handle
# ══════════════════════════════════════════════════════

# ── handle catches die via Exn handler ────────────────

subtest 'handle catches die via Exn => throw' => sub {
    reset_handlers();

    my $result = handle {
        die "boom\n";
        "unreachable";
    } Exn => +{
        throw => sub ($err) { "caught: $err" },
    };

    is $result, "caught: boom\n", 'Exn throw handler receives die error';
};

# ── handle catches Exn::throw via Exn handler ────────

subtest 'handle catches Exn::throw via Exn => throw' => sub {
    reset_handlers();

    my $result = handle {
        Exn::throw("explicit\n");
        "unreachable";
    } Exn => +{
        throw => sub ($err) { "caught: $err" },
    };

    is $result, "caught: explicit\n", 'Exn::throw bridged through die to handler';
};

# ── without Exn handler, die still propagates ─────────

subtest 'die propagates without Exn handler' => sub {
    reset_handlers();

    eval {
        handle {
            die "no-exn-handler\n";
        } Console => +{
            log => sub ($msg) { },
        };
    };
    is $@, "no-exn-handler\n", 'die re-raised when no Exn handler';
};

# ── Exn handler with other effects ────────────────────

subtest 'Exn handler coexists with other effects' => sub {
    reset_handlers();

    my @logs;
    my $result = handle {
        Console::log("before");
        die "mid-error\n";
        Console::log("after");  # unreachable
        "normal";
    } Console => +{
        log => sub ($msg) { push @logs, $msg },
    }, Exn => +{
        throw => sub ($err) { "recovered" },
    };

    is_deeply \@logs, ["before"], 'Console handler ran before die';
    is $result, "recovered", 'Exn handler provided fallback value';
};

# ── Exn handler cleans up other handlers ──────────────

subtest 'Exn handler: all handlers popped after catch' => sub {
    reset_handlers();

    handle {
        die "cleanup-test\n";
    } Console => +{
        log => sub ($msg) { },
    }, Exn => +{
        throw => sub ($err) { "ok" },
    };

    eval { Console::log("test") };
    like $@, qr/No handler for effect Console::log/,
        'Console handler popped after Exn catch';
};

# ── Nested handle with Exn ────────────────────────────

subtest 'nested handle: inner Exn catches, outer unaffected' => sub {
    reset_handlers();

    my @outer_logs;
    my $result = handle {
        my $inner = handle {
            die "inner-boom\n";
        } Exn => +{
            throw => sub ($err) { "inner-caught" },
        };

        Console::log("after-inner: $inner");
        $inner;
    } Console => +{
        log => sub ($msg) { push @outer_logs, $msg },
    };

    is $result, "inner-caught", 'inner Exn handler caught die';
    is_deeply \@outer_logs, ["after-inner: inner-caught"],
        'outer handle continued normally after inner catch';
};

# ── Exn::throw without handler dies normally ──────────

subtest 'Exn::throw without handle dies normally' => sub {
    reset_handlers();

    eval { Exn::throw("raw-throw\n") };
    is $@, "raw-throw\n", 'Exn::throw is just die without handle';
};

done_testing;
