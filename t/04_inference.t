use v5.40;
use Test::More;
use lib 'lib';
use Typist::Inference;
use Typist::Parser;

sub infer { Typist::Inference->infer_value(@_) }
sub parse { Typist::Parser->parse(@_) }

# ── Scalar inference ─────────────────────────────

subtest 'scalar inference' => sub {
    is infer(undef)->to_string,   'Undef', 'undef -> Undef';
    is infer(1)->to_string,       'Bool',  '1 -> Bool';
    is infer(0)->to_string,       'Bool',  '0 -> Bool';
    is infer(42)->to_string,      'Int',   '42 -> Int';
    is infer(-7)->to_string,      'Int',   '-7 -> Int';
    is infer(3.14)->to_string,    'Num',   '3.14 -> Num';
    is infer("hello")->to_string, 'Str',   '"hello" -> Str';
};

# ── Compound inference ───────────────────────────

subtest 'array inference' => sub {
    is infer([])->to_string, 'ArrayRef[Any]', 'empty array -> ArrayRef[Any]';
    is infer([1,2,3])->to_string, 'ArrayRef[Int]', '[1,2,3] -> ArrayRef[Int]';
    is infer([1, 3.14])->to_string, 'ArrayRef[Num]', '[1, 3.14] -> ArrayRef[Num]';
    is infer(["a", "b"])->to_string, 'ArrayRef[Str]', '["a","b"] -> ArrayRef[Str]';
};

subtest 'hash inference' => sub {
    is infer(+{})->to_string, 'HashRef[Any]', 'empty hash -> HashRef[Any]';
    is infer(+{a => 1, b => 2})->to_string, 'HashRef[Int]', '{a=>1,b=>2} -> HashRef[Int]';
};

subtest 'code inference' => sub {
    is infer(sub {})->to_string, 'Any', 'coderef -> Any';
};

# ── Generic instantiation ────────────────────────

subtest 'generic instantiation' => sub {
    # Simulate :sig(<T>(ArrayRef[T]) -> T)
    my $sig = +{
        params   => [parse('ArrayRef[T]')],
        returns  => parse('T'),
        generics => ['T'],
    };

    my @args = ([1, 2, 3]);
    my @arg_types = map { Typist::Inference->infer_value($_) } @args;
    my $bindings = Typist::Inference->instantiate($sig, \@arg_types);

    ok exists $bindings->{T}, 'T was bound';
    is $bindings->{T}->to_string, 'Int', 'T bound to Int';

    my $resolved_return = $sig->{returns}->substitute($bindings);
    is $resolved_return->to_string, 'Int', 'return type resolves to Int';
};

subtest 'generic with strings' => sub {
    my $sig = +{
        params   => [parse('ArrayRef[T]')],
        returns  => parse('T'),
        generics => ['T'],
    };

    my @args = (["hello", "world"]);
    my @arg_types = map { Typist::Inference->infer_value($_) } @args;
    my $bindings = Typist::Inference->instantiate($sig, \@arg_types);

    is $bindings->{T}->to_string, 'Str', 'T bound to Str for string array';
};

subtest 'multi-param generic' => sub {
    # :sig(<K, V>(HashRef[K, V]) -> ArrayRef[V])
    my $sig = +{
        params   => [parse('HashRef[T]')],
        returns  => parse('ArrayRef[T]'),
        generics => ['T'],
    };

    my @args = (+{x => 1, y => 2});
    my @arg_types = map { Typist::Inference->infer_value($_) } @args;
    my $bindings = Typist::Inference->instantiate($sig, \@arg_types);

    is $bindings->{T}->to_string, 'Int', 'T bound to Int from hash values';
};

done_testing;
