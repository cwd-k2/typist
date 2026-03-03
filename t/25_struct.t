use v5.40;
use Test::More;
use lib 'lib';

BEGIN { $ENV{TYPIST_CHECK_QUIET} = 1 }

use Typist;
use Typist::DSL qw(:all);
use Typist::Subtype;
use Typist::Registry;

# ── Basic struct declaration ──────────────────

struct Person => (name => Str, age => Int);

subtest 'struct creates constructor' => sub {
    ok defined(&Person), 'Person constructor exists';
    my $p = Person(name => "Alice", age => 30);
    ok defined $p, 'constructor returns value';
    isa_ok $p, 'Typist::Struct::Person';
    isa_ok $p, 'Typist::Struct::Base';
};

subtest 'struct accessors' => sub {
    my $p = Person(name => "Bob", age => 25);
    is $p->name, "Bob",  'name accessor';
    is $p->age,  25,     'age accessor';
};

subtest 'struct immutable update' => sub {
    my $p1 = Person(name => "Alice", age => 30);
    my $p2 = $p1->with(age => 31);
    is $p1->age, 30, 'original unchanged';
    is $p2->age, 31, 'updated value';
    is $p2->name, "Alice", 'non-updated field preserved';
    isa_ok $p2, 'Typist::Struct::Person';
};

subtest 'struct with() rejects unknown fields' => sub {
    my $p = Person(name => "Alice", age => 30);
    my $died = !eval { $p->with(unknown => 1); 1 };
    ok $died, 'with() dies on unknown field';
    like $@, qr/Unknown field 'unknown'/, 'error message';
};

# ── Required field validation ─────────────────

subtest 'struct requires all required fields' => sub {
    my $died = !eval { Person(name => "Alice"); 1 };
    ok $died, 'dies when required field missing';
    like $@, qr/missing required field 'age'/, 'error message for missing field';
};

subtest 'struct rejects unknown fields' => sub {
    my $died = !eval { Person(name => "Alice", age => 30, hair => "brown"); 1 };
    ok $died, 'dies on unknown field';
    like $@, qr/unknown field 'hair'/, 'error message for unknown field';
};

# ── Optional fields ──────────────────────────

struct Config => (host => Str, port => Int, debug => optional(Bool));

subtest 'struct with optional field' => sub {
    my $c1 = Config(host => "localhost", port => 8080);
    is $c1->host, "localhost", 'required field';
    is $c1->port, 8080,       'required field';
    is $c1->debug, undef,     'optional field defaults to undef';

    my $c2 = Config(host => "localhost", port => 8080, debug => 1);
    ok $c2->debug, 'optional field when provided';
};

# ── Type registration ─────────────────────────

subtest 'struct registered as type' => sub {
    my $type = Typist::Registry->lookup_type('Person');
    ok $type, 'Person type registered';
    ok $type->is_struct, 'is_struct predicate';
    is $type->name, 'Person', 'type name';
};

# ── Nominal subtyping ────────────────────────

subtest 'struct <: record (structural compatibility)' => sub {
    my $person_type = Typist::Registry->lookup_type('Person');
    my $record_type = Typist::Type::Record->new(name => Str, age => Int);
    ok Typist::Subtype->is_subtype($person_type, $record_type),
        'Person <: {name => Str, age => Int}';
};

subtest 'record </: struct (nominal barrier)' => sub {
    my $person_type = Typist::Registry->lookup_type('Person');
    my $record_type = Typist::Type::Record->new(name => Str, age => Int);
    ok !Typist::Subtype->is_subtype($record_type, $person_type),
        '{name => Str, age => Int} </: Person';
};

subtest 'different structs are incompatible' => sub {
    struct Point => (x => Int, y => Int);
    struct Pair  => (x => Int, y => Int);
    my $point = Typist::Registry->lookup_type('Point');
    my $pair  = Typist::Registry->lookup_type('Pair');
    ok !Typist::Subtype->is_subtype($point, $pair),
        'Point </: Pair (different nominal types)';
};

# ── contains (runtime value test) ────────────

subtest 'struct contains checks blessed type' => sub {
    my $type = Typist::Registry->lookup_type('Person');
    my $p = Person(name => "Alice", age => 30);
    ok $type->contains($p), 'Person instance satisfies Person type';
    ok !$type->contains(+{ name => "Alice", age => 30 }),
        'plain hashref does not satisfy Person type';
};

# ── Runtime type validation ──────────────────

subtest 'boundary type validation (always-on)' => sub {
    my $died = !eval { Person(name => "Alice", age => "not_a_number"); 1 };
    ok $died, 'constructor rejects invalid type without -runtime';
    like $@, qr/field 'age' expected Int/, 'error names the field and expected type';
};

# ── Generic struct ──────────────────────────────

struct 'Pair[T, U]' => (fst => T, snd => U);

subtest 'generic struct: construction' => sub {
    my $p = Pair(fst => 42, snd => "hi");
    ok defined $p, 'constructor returns value';
    isa_ok $p, 'Typist::Struct::Pair';
    isa_ok $p, 'Typist::Struct::Base';
    is $p->fst, 42,   'fst accessor';
    is $p->snd, "hi", 'snd accessor';
};

subtest 'generic struct: type_args inferred' => sub {
    my $p = Pair(fst => 42, snd => "hi");
    ok $p->{_type_args}, 'type_args recorded';
    is scalar @{$p->{_type_args}}, 2, 'two type args';
    is $p->{_type_args}[0]->name, 'Int', 'T = Int';
    is $p->{_type_args}[1]->name, 'Str', 'U = Str';
};

subtest 'generic struct: with() preserves type_args' => sub {
    my $p1 = Pair(fst => 42, snd => "hello");
    my $p2 = $p1->with(snd => "world");
    is $p2->fst, 42,      'fst preserved';
    is $p2->snd, "world", 'snd updated';
    ok $p2->{_type_args}, 'type_args preserved after with()';
    is $p2->{_type_args}[0]->name, 'Int', 'T preserved';
};

subtest 'generic struct: type registered with type_params' => sub {
    my $type = Typist::Registry->lookup_type('Pair');
    ok $type, 'Pair type registered';
    ok $type->is_struct, 'is_struct predicate';
    my @tp = $type->type_params;
    is scalar @tp, 2, 'two type params';
    is $tp[0], 'T', 'first param is T';
    is $tp[1], 'U', 'second param is U';
};

subtest 'generic struct: boundary validation' => sub {
    # All field values must be consistent — T binds to the first occurrence
    my $died = !eval { Pair(fst => 1, snd => 2); 1 };
    ok !$died, 'Pair(fst => 1, snd => 2) succeeds (T=Int, U=Int)';
};

subtest 'generic struct: to_string with type_params' => sub {
    my $type = Typist::Registry->lookup_type('Pair');
    like $type->to_string, qr/Pair\[T, U\]/, 'to_string shows type params';
};

# ── Generic struct + :sig() integration ────────────

subtest 'generic struct: Param ↔ Struct subtype via Subtype bridge' => sub {
    require Typist::Type::Param;
    require Typist::Type::Alias;
    require Typist::Type::Atom;

    my $pair_type = Typist::Registry->lookup_type('Pair');
    my $concrete = $pair_type->instantiate(
        Typist::Type::Atom->new('Int'), Typist::Type::Atom->new('Str'),
    );

    # Simulate what Parser produces for Pair[Int, Str] in :sig()
    my $param = Typist::Type::Param->new(
        Typist::Type::Alias->new('Pair'),
        Typist::Type::Atom->new('Int'),
        Typist::Type::Atom->new('Str'),
    );

    ok Typist::Subtype->is_subtype($concrete, $param),
        'Struct Pair[Int, Str] <: Param Pair[Int, Str]';
    ok Typist::Subtype->is_subtype($param, $concrete),
        'Param Pair[Int, Str] <: Struct Pair[Int, Str]';
};

subtest 'generic struct: resolve_struct_params transform' => sub {
    require Typist::Transform;
    require Typist::Type::Param;
    require Typist::Type::Alias;
    require Typist::Type::Atom;

    # Param(Alias('Pair'), [Int, Str]) should resolve to Struct
    my $param = Typist::Type::Param->new(
        Typist::Type::Alias->new('Pair'),
        Typist::Type::Atom->new('Int'),
        Typist::Type::Atom->new('Str'),
    );
    my $resolved = Typist::Transform->resolve_struct_params(
        $param, 'Typist::Registry'
    );
    ok $resolved->is_struct, 'Param resolved to Struct';
    is $resolved->name, 'Pair', 'resolved struct name';
    my @ta = $resolved->type_args;
    is scalar @ta, 2, 'two type args';
    ok $ta[0]->is_atom && $ta[0]->name eq 'Int', 'T = Int';
    ok $ta[1]->is_atom && $ta[1]->name eq 'Str', 'U = Str';
};

done_testing;
