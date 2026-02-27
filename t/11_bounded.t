use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;
use Typist::Type::Var;
use Typist::Subtype;
use Typist::Inference;

# ── Var with bound ───────────────────────────────

subtest 'var with bound' => sub {
    my $bound = Typist::Parser->parse('Num');
    my $v = Typist::Type::Var->new('T', bound => $bound);

    ok  $v->is_var, 'is var';
    is  $v->name, 'T', 'name';
    ok  $v->bound, 'has bound';
    is  $v->bound->to_string, 'Num', 'bound is Num';
    is  $v->to_string, 'T: Num', 'to_string with bound';
};

subtest 'var without bound' => sub {
    my $v = Typist::Type::Var->new('U');
    ok  $v->is_var, 'is var';
    ok !$v->bound,  'no bound';
    is  $v->to_string, 'U', 'to_string without bound';
};

# ── Runtime bound checking via attribute wrapper ──

subtest 'bounded generic function accepts valid types' => sub {
    # Simulate the wrapper behavior manually
    my $sig = +{
        params   => [Typist::Type::Var->new('T')],
        returns  => Typist::Type::Var->new('T'),
        generics => [+{ name => 'T', bound_expr => 'Num' }],
    };

    # Int <: Num — should pass
    my @arg_types = (Typist::Inference->infer_value(42));
    my $bindings = Typist::Inference->instantiate($sig, \@arg_types);

    my $bound = Typist::Parser->parse('Num');
    my $actual = $bindings->{T};
    ok Typist::Subtype->is_subtype($actual, $bound),
        'Int (inferred from 42) <: Num bound — valid';
};

subtest 'bounded generic rejects out-of-bound types' => sub {
    my $sig = +{
        params   => [Typist::Type::Var->new('T')],
        returns  => Typist::Type::Var->new('T'),
        generics => [+{ name => 'T', bound_expr => 'Num' }],
    };

    # Str </: Num — should fail
    my @arg_types = (Typist::Inference->infer_value('hello'));
    my $bindings = Typist::Inference->instantiate($sig, \@arg_types);

    my $bound = Typist::Parser->parse('Num');
    my $actual = $bindings->{T};
    ok !Typist::Subtype->is_subtype($actual, $bound),
        'Str (inferred from "hello") </: Num bound — rejected';
};

subtest 'multi-char bounded var' => sub {
    my $bound = Typist::Parser->parse('Int');
    my $v = Typist::Type::Var->new('Elem', bound => $bound);
    is $v->to_string, 'Elem: Int', 'multi-char var with bound';
};

done_testing;
