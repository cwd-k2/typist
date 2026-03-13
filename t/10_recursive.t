use v5.40;
use Test::More;
use lib 'lib';
use Typist::Parser;
use Typist::Registry;
use Typist::Subtype;

sub parse  { Typist::Parser->parse(@_) }
sub is_sub { Typist::Subtype->is_subtype(@_) }

# ── Productive recursion (through type constructors) ──

subtest 'recursive typedef resolves' => sub {
    Typist::Registry->reset;
    Typist::Registry->define_alias('IntList', 'ArrayRef[IntList] | Int');

    my $type = Typist::Registry->lookup_type('IntList');
    ok defined $type, 'IntList resolves';
    ok $type->is_union, 'IntList is union (ArrayRef[IntList] | Int)';
};

subtest 'recursive contains - simple values' => sub {
    Typist::Registry->reset;
    Typist::Registry->define_alias('IntList', 'Int | ArrayRef[IntList]');

    my $type = parse('IntList');

    ok  $type->contains(42),          'IntList contains plain Int';
    ok  $type->contains([1, 2, 3]),   'IntList contains flat array';
    ok  $type->contains([1, [2, 3]]), 'IntList contains nested array';
    ok  $type->contains([]),          'IntList contains empty array';
    ok !$type->contains('hello'),     'IntList does not contain Str';
};

subtest 'JSON-like recursive type' => sub {
    Typist::Registry->reset;
    Typist::Registry->define_alias(
        'JsonValue',
        'Str | Num | Bool | Undef | ArrayRef[JsonValue] | HashRef[Str, JsonValue]',
    );

    my $type = parse('JsonValue');

    ok  $type->contains('hello'),                  'JsonValue: string';
    ok  $type->contains(42),                       'JsonValue: number';
    ok  $type->contains(1),                        'JsonValue: bool';
    ok  $type->contains(undef),                    'JsonValue: null';
    ok  $type->contains([1, 'two', undef]),        'JsonValue: array';
    ok  $type->contains(+{ key => 'value' }),      'JsonValue: object';
    ok  $type->contains(+{ a => [1, +{ b => 2 }] }), 'JsonValue: nested';
};

# ── Non-productive cycle still errors ──

subtest 'bare cycle still errors' => sub {
    Typist::Registry->reset;
    Typist::Registry->define_alias('Loop1', 'Loop2');
    Typist::Registry->define_alias('Loop2', 'Loop1');

    my $err;
    eval { Typist::Registry->lookup_type('Loop1') };
    $err = $@;
    ok $err && (ref $err eq 'HASH' ? ($err->{type} // '') eq 'CycleError' : $err =~ /cycle/),
       'bare cycle detected for Loop1';
};

subtest 'recursive depth limit prevents infinite loop' => sub {
    Typist::Registry->reset;
    # Deeply nested: each level adds another ArrayRef layer
    Typist::Registry->define_alias('Deep', 'ArrayRef[Deep]');

    my $type = parse('Deep');
    # Should not hang — depth limit kicks in
    ok !$type->contains(42), 'non-matching value rejected within depth limit';
    # Empty array matches ArrayRef[anything]
    ok  $type->contains([]), 'empty array matches';
};

done_testing;
