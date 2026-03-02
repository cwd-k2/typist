use v5.40;
use Test::More;
use lib 'lib';
use Typist -runtime;

# ── End-to-end: typed scalars ────────────────────

subtest 'typed scalar lifecycle' => sub {
    my $count :sig(Int) = 0;
    is $count, 0, 'initial value';

    $count = 10;
    is $count, 10, 'updated value';

    eval { $count = "many" };
    like $@, qr/type error/, 'rejected string';
    is $count, 10, 'value preserved after error';
};

# ── End-to-end: typed functions ──────────────────

subtest 'typed function pipeline' => sub {
    sub double :sig((Int) -> Int) ($n) {
        return $n * 2;
    }

    sub to_greeting :sig((Str) -> Str) ($name) {
        return "Hello, $name!";
    }

    is double(21), 42, 'double(21) = 42';
    is to_greeting("World"), "Hello, World!", 'greeting works';

    eval { double("oops") };
    like $@, qr/param 1 expected Int/, 'double rejects string';
};

# ── End-to-end: typedef + typed scalar ───────────

subtest 'typedef integration' => sub {
    typedef Age => 'Int';

    my $age :sig(Age) = 25;
    is $age, 25, 'Age accepted 25';

    $age = 30;
    is $age, 30, 'Age accepted 30';

    eval { $age = "young" };
    like $@, qr/type error/, 'Age rejected string';
};

# ── End-to-end: parameterized + functions ────────

subtest 'parameterized function' => sub {
    sub sum_list :sig((ArrayRef[Int]) -> Int) ($list) {
        my $sum = 0;
        $sum += $_ for @$list;
        return $sum;
    }

    is sum_list([1, 2, 3, 4]), 10, 'sum_list([1,2,3,4]) = 10';
    is sum_list([]),            0,  'sum_list([]) = 0';

    eval { sum_list("not_an_array") };
    like $@, qr/param 1 expected ArrayRef/, 'rejected non-array';
};

# ── End-to-end: generic function ─────────────────

subtest 'generic function' => sub {
    sub first :sig(<T>(ArrayRef[T]) -> T) ($arr) {
        return $arr->[0];
    }

    is first([10, 20, 30]), 10, 'first([10,20,30]) = 10';
    is first(["a", "b"]), "a", 'first(["a","b"]) = "a"';
};

# ── End-to-end: Maybe types ─────────────────────

subtest 'Maybe type flow' => sub {
    my $opt :sig(Maybe[Int]) = 42;
    is $opt, 42, 'Maybe[Int] holds 42';

    $opt = undef;
    is $opt, undef, 'Maybe[Int] holds undef';

    eval { $opt = "nope" };
    like $@, qr/type error/, 'Maybe[Int] rejects string';
};

# ── End-to-end: struct validation ────────────────

subtest 'struct type on scalar' => sub {
    my $person :sig({ name => Str, age => Int }) = +{ name => "Alice", age => 30 };
    is $person->{name}, "Alice", 'struct field access';

    eval {
        my $bad :sig({ name => Str, age => Int }) = +{ name => "Bob" };
    };
    like $@, qr/type error/, 'struct rejects missing field';
};

# ── End-to-end: union types ──────────────────────

subtest 'union type on scalar' => sub {
    my $val :sig(Int | Str) = 42;
    is $val, 42, 'union accepted Int';

    $val = "hello";
    is $val, "hello", 'union accepted Str';

    eval { $val = [1, 2] };
    like $@, qr/type error/, 'union rejected arrayref';
};

done_testing;
