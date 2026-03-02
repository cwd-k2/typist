use v5.40;
use Test::More;
use lib 'lib';

BEGIN { $ENV{TYPIST_CHECK_QUIET} = 1 }

use Typist;
use Typist::DSL;
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

subtest 'runtime type validation' => sub {
    local $Typist::RUNTIME = 1;
    my $died = !eval { Person(name => "Alice", age => "not_a_number"); 1 };
    ok $died, 'runtime rejects invalid type';
    like $@, qr/field 'age' expected Int/, 'error names the field and expected type';
};

done_testing;
