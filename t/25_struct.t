use v5.40;
use Test::More;
use lib 'lib', 't/lib';

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
};

subtest 'struct accessors' => sub {
    my $p = Person(name => "Bob", age => 25);
    is $p->name, "Bob",  'name accessor';
    is $p->age,  25,     'age accessor';
};

subtest 'struct immutable derive' => sub {
    my $p1 = Person(name => "Alice", age => 30);
    my $p2 = Person::derive($p1, age => 31);
    is $p1->age, 30, 'original unchanged';
    is $p2->age, 31, 'derived value';
    is $p2->name, "Alice", 'non-derived field preserved';
    isa_ok $p2, 'Typist::Struct::Person';
};

subtest 'struct derive rejects unknown fields' => sub {
    my $p = Person(name => "Alice", age => 30);
    my $died = !eval { Person::derive($p, unknown => 1); 1 };
    ok $died, 'derive dies on unknown field';
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

struct Config => (host => Str, port => Int, optional(debug => Bool));

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

subtest 'boundary type validation (runtime)' => sub {
    local $Typist::RUNTIME = 1;
    my $died = !eval { Person(name => "Alice", age => "not_a_number"); 1 };
    ok $died, 'constructor rejects invalid type with runtime';
    like $@, qr/field 'age' expected Int/, 'error names the field and expected type';
};

subtest 'constructor skips type validation without runtime' => sub {
    local $Typist::RUNTIME = 0;
    my $p = eval { Person(name => "Alice", age => "not_a_number"); };
    ok defined $p, 'constructor succeeds without runtime (type check skipped)';
};

# ── Generic struct ──────────────────────────────

struct 'Pair[T, U]' => (fst => T, snd => U);

subtest 'generic struct: construction' => sub {
    my $p = Pair(fst => 42, snd => "hi");
    ok defined $p, 'constructor returns value';
    isa_ok $p, 'Typist::Struct::Pair';
    is $p->fst, 42,   'fst accessor';
    is $p->snd, "hi", 'snd accessor';
};

subtest 'generic struct: type_args inferred (runtime)' => sub {
    local $Typist::RUNTIME = 1;
    my $p = Pair(fst => 42, snd => "hi");
    ok $p->{_type_args}, 'type_args recorded';
    is scalar @{$p->{_type_args}}, 2, 'two type args';
    is $p->{_type_args}[0]->name, 'Int', 'T = Int';
    is $p->{_type_args}[1]->name, 'Str', 'U = Str';
};

subtest 'generic struct: no type_args without runtime' => sub {
    local $Typist::RUNTIME = 0;
    my $p = Pair(fst => 42, snd => "hi");
    ok !$p->{_type_args}, 'no type_args in static-only mode';
};

subtest 'generic struct: derive preserves type_args (runtime)' => sub {
    local $Typist::RUNTIME = 1;
    my $p1 = Pair(fst => 42, snd => "hello");
    my $p2 = Pair::derive($p1, snd => "world");
    is $p2->fst, 42,      'fst preserved';
    is $p2->snd, "world", 'snd derived';
    ok $p2->{_type_args}, 'type_args preserved after derive';
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

# ── Bounded generic struct ──────────────────────

struct 'NumBox[T: Num]' => (val => T);

subtest 'bounded struct: Int satisfies Num bound' => sub {
    my $nb = NumBox(val => 42);
    ok defined $nb, 'NumBox(val => 42) succeeds';
    is $nb->val, 42, 'val accessor';
};

subtest 'bounded struct: Double satisfies Num bound' => sub {
    my $nb = NumBox(val => 3.14);
    ok defined $nb, 'NumBox(val => 3.14) succeeds';
};

subtest 'bounded struct: Str violates Num bound (runtime)' => sub {
    local $Typist::RUNTIME = 1;
    my $died = !eval { NumBox(val => "hello"); 1 };
    ok $died, 'dies when bound violated';
    like $@, qr/does not satisfy bound Num for T/, 'error message';
};

subtest 'bounded struct: to_string shows bounds' => sub {
    my $type = Typist::Registry->lookup_type('NumBox');
    like $type->to_string, qr/NumBox\[T: Num\]/, 'to_string shows T: Num';
};

# ── Typeclass-constrained generic struct ────────

typeclass Show => T, +{ show => '(T) -> Str' };
instance Show => Int, +{ show => sub ($x) { "$x" } };

struct 'ShowBox[T: Show]' => (val => T);

subtest 'typeclass struct: Int has Show instance' => sub {
    my $sb = ShowBox(val => 42);
    ok defined $sb, 'ShowBox(val => 42) succeeds';
};

subtest 'typeclass struct: Str has no Show instance (runtime)' => sub {
    local $Typist::RUNTIME = 1;
    my $died = !eval { ShowBox(val => "hello"); 1 };
    ok $died, 'dies when typeclass constraint violated';
    like $@, qr/no instance of Show for Str/, 'error message';
};

# ── Mixed: bounded + unbounded ──────────────────

struct 'Mixed[T: Num, U]' => (val => T, extra => U);

subtest 'mixed params: bounded satisfied' => sub {
    my $m = Mixed(val => 42, extra => "anything");
    ok defined $m, 'Mixed(val => 42, extra => "anything") succeeds';
    is $m->val, 42, 'val accessor';
    is $m->extra, "anything", 'extra accessor';
};

subtest 'mixed params: bounded violated (runtime)' => sub {
    local $Typist::RUNTIME = 1;
    my $died = !eval { Mixed(val => "hello", extra => 1); 1 };
    ok $died, 'dies when bounded param violated';
    like $@, qr/does not satisfy bound Num for T/, 'error message';
};

done_testing;
