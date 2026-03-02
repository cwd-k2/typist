use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Extractor;
use Typist::Static::Registration;
use Typist::Static::Infer;
use Typist::Static::TypeChecker;
use Typist::Registry;
use Typist::Error;

# ── Extraction ────────────────────────────────

subtest 'extractor recognizes struct declarations' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    ok exists $extracted->{structs}{Person}, 'Person struct extracted';

    my $info = $extracted->{structs}{Person};
    is $info->{fields}{name}, 'Str', 'name field type';
    is $info->{fields}{age},  'Int', 'age field type';
    is_deeply $info->{optional_fields}, [], 'no optional fields';
    is_deeply $info->{type_params}, [], 'no type params';
};

subtest 'extractor handles optional fields' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct Config => (host => Str, port => Int, debug => optional(Bool));
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    ok exists $extracted->{structs}{Config}, 'Config struct extracted';

    my $info = $extracted->{structs}{Config};
    is $info->{fields}{host},  'Str',  'required field type';
    is $info->{fields}{port},  'Int',  'required field type';
    is $info->{fields}{debug}, 'Bool', 'optional field inner type';
    is_deeply $info->{optional_fields}, ['debug'], 'optional field listed';
};

# ── Registration ──────────────────────────────

subtest 'registration creates struct type and constructor' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_structs($extracted, $registry);

    # Struct type registered
    my $type = $registry->lookup_type('Person');
    ok $type, 'Person type registered';
    ok $type->is_struct, 'type is struct';
    is $type->name, 'Person', 'struct name';

    # Constructor registered as function
    my $pkg = $extracted->{package};
    my $fn = $registry->lookup_function($pkg, 'Person');
    ok $fn, 'Person constructor registered';
    ok $fn->{returns}->is_struct, 'constructor returns struct type';
    is $fn->{returns}->name, 'Person', 'constructor returns Person';

    # Accessor methods registered
    my $name_method = $registry->lookup_method('Typist::Struct::Person', 'name');
    ok $name_method, 'name accessor method registered';
    ok $name_method->{returns}->is_atom && $name_method->{returns}->name eq 'Str',
        'name accessor returns Str';

    my $age_method = $registry->lookup_method('Typist::Struct::Person', 'age');
    ok $age_method, 'age accessor method registered';
    ok $age_method->{returns}->is_atom && $age_method->{returns}->name eq 'Int',
        'age accessor returns Int';

    # with() method registered
    my $with_method = $registry->lookup_method('Typist::Struct::Person', 'with');
    ok $with_method, 'with method registered';
    ok $with_method->{returns}->is_struct, 'with returns struct type';
};

# ── Inference ─────────────────────────────────

subtest 'infer struct constructor return type' => sub {
    my $source = <<'PERL';
package main;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
sub test :Type((Person) -> Void) ($p) {
    my $x = $p;
}
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_all($extracted, $registry);

    # Build env with Person type in variables
    my $person_type = $registry->lookup_type('Person');
    my $env = +{
        variables => +{ '$p' => $person_type },
        functions => +{},
        registry  => $registry,
    };

    # Test: Person(...) infers as Person type
    my $ppi = PPI::Document->new(\q{ Person(name => "Alice", age => 30) });
    my $expr = $ppi->find_first('PPI::Token::Word');
    my $result = Typist::Static::Infer->infer_expr($expr, $env);
    ok $result, 'constructor infers a type';
    ok $result->is_struct, 'constructor infers struct type';
    is $result->name, 'Person', 'constructor infers Person';
};

subtest 'infer struct accessor type' => sub {
    my $source = <<'PERL';
package main;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_all($extracted, $registry);

    my $person_type = $registry->lookup_type('Person');
    my $env = +{
        variables => +{ '$p' => $person_type },
        functions => +{},
        registry  => $registry,
    };

    # Test: $p->name infers as Str
    my $ppi = PPI::Document->new(\q{ $p->name });
    my $sym = $ppi->find_first('PPI::Token::Symbol');
    my $result = Typist::Static::Infer->infer_expr($sym, $env);
    ok $result, 'accessor infers a type';
    ok $result->is_atom && $result->name eq 'Str',
        '$p->name infers as Str';
};

subtest 'infer struct with() return type' => sub {
    my $source = <<'PERL';
package main;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_all($extracted, $registry);

    my $person_type = $registry->lookup_type('Person');
    my $env = +{
        variables => +{ '$p' => $person_type },
        functions => +{},
        registry  => $registry,
    };

    # Test: $p->with(age => 31) infers as Person
    my $ppi = PPI::Document->new(\q{ $p->with(age => 31) });
    my $sym = $ppi->find_first('PPI::Token::Symbol');
    my $result = Typist::Static::Infer->infer_expr($sym, $env);
    ok $result, 'with() infers a type';
    ok $result->is_struct, 'with() infers struct type';
    is $result->name, 'Person', 'with() returns same struct type';
};

subtest 'infer chained accessor: Person(...)->name' => sub {
    my $source = <<'PERL';
package main;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_all($extracted, $registry);

    my $env = +{
        variables => +{},
        functions => +{},
        registry  => $registry,
    };

    # Test: Person(name => "Alice", age => 30)->name infers as Str
    my $ppi = PPI::Document->new(\q{ Person(name => "Alice", age => 30)->name });
    my $word = $ppi->find_first('PPI::Token::Word');
    my $result = Typist::Static::Infer->infer_expr($word, $env);
    ok $result, 'chained accessor infers a type';
    ok $result->is_atom && $result->name eq 'Str',
        'Person(...)->name infers as Str';
};

done_testing;
