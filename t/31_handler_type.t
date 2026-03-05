use v5.40;
use Test::More;
use lib 'lib';

use Typist::Parser;
use Typist::Subtype;
use Typist::Registry;
use Typist::Effect;
use Typist::DSL qw(:all);

sub parse { Typist::Parser->parse(@_) }
sub is_sub { Typist::Subtype->is_subtype(@_) }

# ── Register effects for testing ────────────────

Typist::Registry->register_effect('Console', Typist::Effect->new(
    name       => 'Console',
    operations => +{
        readLine  => '() -> Str',
        writeLine => '(Str) -> Void',
    },
));

Typist::Registry->register_effect('State', Typist::Effect->new(
    name       => 'State',
    operations => +{
        get => '() -> Int',
        put => '(Int) -> Void',
    },
));

# ── Parse ────────────────────────────────────────

subtest 'Handler[E] parses as Param' => sub {
    my $t = parse('Handler[Console]');
    ok $t->is_param, 'is_param';
    is $t->base, 'Handler', 'base is Handler';
    is $t->to_string, 'Handler[Console]', 'to_string';
};

# ── DSL constructor ──────────────────────────────

subtest 'Handler DSL constructor' => sub {
    my $t = Handler(Alias('Console'));
    ok $t->is_param, 'is_param';
    is $t->base, 'Handler', 'base is Handler';
};

# ── Subtype: Handler[E] identity ─────────────────

subtest 'Handler[E] <: Handler[E]' => sub {
    ok is_sub(parse('Handler[Console]'), parse('Handler[Console]')),
        'Handler[Console] <: Handler[Console]';
};

# ── Subtype: Handler[E] <: Record ────────────────

subtest 'Handler[E] <: matching Record' => sub {
    my $handler = parse('Handler[Console]');
    my $record  = parse('{ readLine => () -> Str, writeLine => (Str) -> Void }');
    ok is_sub($handler, $record), 'Handler[Console] <: { readLine, writeLine }';
};

subtest 'Handler[E] <: wider Record (width subtyping)' => sub {
    my $handler = parse('Handler[Console]');
    my $record  = parse('{ readLine => () -> Str }');
    ok is_sub($handler, $record), 'Handler[Console] <: { readLine } (has extra fields)';
};

# ── Subtype: Record <: Handler[E] ────────────────

subtest 'matching Record <: Handler[E]' => sub {
    my $record  = parse('{ readLine => () -> Str, writeLine => (Str) -> Void }');
    my $handler = parse('Handler[Console]');
    ok is_sub($record, $handler), '{ readLine, writeLine } <: Handler[Console]';
};

subtest 'wider Record <: Handler[E]' => sub {
    my $record  = parse('{ readLine => () -> Str, writeLine => (Str) -> Void, extra => Int }');
    my $handler = parse('Handler[Console]');
    ok is_sub($record, $handler), '{ readLine, writeLine, extra } <: Handler[Console]';
};

subtest 'partial Record </: Handler[E]' => sub {
    my $record  = parse('{ readLine => () -> Str }');
    my $handler = parse('Handler[Console]');
    ok !is_sub($record, $handler), '{ readLine } </: Handler[Console] (missing writeLine)';
};

subtest 'wrong type Record </: Handler[E]' => sub {
    my $record  = parse('{ readLine => () -> Int, writeLine => (Str) -> Void }');
    my $handler = parse('Handler[Console]');
    ok !is_sub($record, $handler), '{ readLine => () -> Int } </: Handler[Console]';
};

# ── Subtype: distinct effects ─────────────────────

subtest 'Handler[A] </: Handler[B]' => sub {
    ok !is_sub(parse('Handler[Console]'), parse('Handler[State]')),
        'Handler[Console] </: Handler[State]';
};

# ── Subtype: Handler[E] <: Any ────────────────────

subtest 'Handler[E] <: Any' => sub {
    ok is_sub(parse('Handler[Console]'), parse('Any')),
        'Handler[Console] <: Any';
};

# ── contains (runtime) ──────────────────────────

subtest 'Handler[E] contains matching hashref' => sub {
    my $t = parse('Handler[Console]');
    ok $t->contains(+{
        readLine  => sub () { "hello" },
        writeLine => sub ($msg) { },
    }), 'hashref with all ops passes contains';
};

subtest 'Handler[E] rejects partial hashref' => sub {
    my $t = parse('Handler[Console]');
    ok !$t->contains(+{
        readLine => sub () { "hello" },
    }), 'hashref missing writeLine fails contains';
};

subtest 'Handler[E] rejects non-hashref' => sub {
    my $t = parse('Handler[Console]');
    ok !$t->contains([1, 2, 3]), 'arrayref fails contains';
    ok !$t->contains(42),        'scalar fails contains';
    ok !$t->contains(undef),     'undef fails contains';
};

done_testing;
