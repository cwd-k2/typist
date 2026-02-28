use v5.40;
use Test::More;
use lib 'lib';
use Typist -runtime;

# ── :Type on scalars ─────────────────────────────

subtest 'scalar :Type(Int)' => sub {
    my $x :Type(Int) = 42;
    is $x, 42, 'Int accepted 42';

    eval { $x = 99 };
    is $@, '', 'Int accepted 99';
    is $x, 99, 'value updated to 99';

    eval { $x = "hello" };
    like $@, qr/type error/, 'Int rejected "hello"';
    is $x, 99, 'value unchanged after rejection';
};

subtest 'scalar :Type(Str)' => sub {
    my $s :Type(Str) = "world";
    is $s, "world", 'Str accepted "world"';

    eval { $s = [1,2,3] };
    like $@, qr/type error/, 'Str rejected arrayref';
};

subtest 'scalar :Type(Num)' => sub {
    my $n :Type(Num) = 3.14;
    is $n, 3.14, 'Num accepted 3.14';

    eval { $n = 42 };
    is $@, '', 'Num accepted 42 (Int is Num)';
};

subtest 'scalar :Type(Bool)' => sub {
    my $b :Type(Bool) = 1;
    is $b, 1, 'Bool accepted 1';

    $b = 0;
    is $b, 0, 'Bool accepted 0';

    eval { $b = 42 };
    like $@, qr/type error/, 'Bool rejected 42';
};

# ── :Type with parameterized types ───────────────

subtest 'scalar :Type(ArrayRef[Int])' => sub {
    my $arr :Type(ArrayRef[Int]) = [1, 2, 3];
    is_deeply $arr, [1, 2, 3], 'ArrayRef[Int] accepted [1,2,3]';

    eval { $arr = [1, "two", 3] };
    like $@, qr/type error/, 'ArrayRef[Int] rejected [1,"two",3]';

    eval { $arr = "not array" };
    like $@, qr/type error/, 'ArrayRef[Int] rejected string';
};

# ── :Type with Maybe (union) ─────────────────────

subtest 'scalar :Type(Maybe[Str])' => sub {
    my $m :Type(Maybe[Str]) = "hello";
    is $m, "hello", 'Maybe[Str] accepted "hello"';

    $m = undef;
    is $m, undef, 'Maybe[Str] accepted undef';

    eval { $m = [1] };
    like $@, qr/type error/, 'Maybe[Str] rejected arrayref';
};

# ── :Type on subs ────────────────────────────────

subtest 'sub :Type function annotation' => sub {
    sub add :Type((Int, Int) -> Int) ($a, $b) {
        return $a + $b;
    }

    is add(2, 3), 5, 'add(2, 3) = 5';

    eval { add("x", 3) };
    like $@, qr/param 1 expected Int/, 'rejected non-Int first param';

    eval { add(2, "y") };
    like $@, qr/param 2 expected Int/, 'rejected non-Int second param';
};

subtest 'sub with return type violation' => sub {
    sub bad_return :Type((Int) -> Int) ($n) {
        return "not a number";
    }

    eval { bad_return(1) };
    like $@, qr/return expected Int/, 'caught return type violation';
};

# ── typedef ──────────────────────────────────────

subtest 'typedef' => sub {
    typedef Name => 'Str';

    my $name :Type(Name) = "Alice";
    is $name, "Alice", 'typedef Name (=Str) accepted "Alice"';

    eval { $name = [1] };
    like $@, qr/type error/, 'typedef Name rejected arrayref';
};

done_testing;
