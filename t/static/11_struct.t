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

    # derive() function registered
    my $derive_fn = $registry->lookup_function('Person', 'derive');
    ok $derive_fn, 'derive function registered';
    ok $derive_fn->{returns}->is_struct, 'derive returns struct type';
};

# ── Inference ─────────────────────────────────

subtest 'infer struct constructor return type' => sub {
    my $source = <<'PERL';
package main;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
sub test :sig((Person) -> Void) ($p) {
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

    # Test: Person::derive($p, age => 31) infers as Person
    my $ppi = PPI::Document->new(\q{ Person::derive($p, age => 31) });
    my $sym = $ppi->find_first('PPI::Token::Word');
    my $result = Typist::Static::Infer->infer_expr($sym, $env);
    ok $result, 'derive infers a type';
    ok $result->is_struct, 'derive infers struct type';
    is $result->name, 'Person', 'derive returns same struct type';
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

subtest 'infer accessor on cross-package function returning alias' => sub {
    # Simulate: Pkg::find() returns Alias("Person"), ->name resolves to Str
    my $source = <<'PERL';
package TestPkg;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
sub find :sig((Int) -> Person) ($id) { Person(name => "x", age => $id) }
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_all($extracted, $registry);

    # Infer from another package's perspective
    my $env = +{
        variables => +{},
        functions => +{},
        registry  => $registry,
        package   => 'main',
    };

    # TestPkg::find(1)->name should infer as Str
    my $ppi = PPI::Document->new(\q{ TestPkg::find(1)->name });
    my $word = $ppi->find_first('PPI::Token::Word');
    my $result = Typist::Static::Infer->infer_expr($word, $env);
    ok $result, 'cross-package chained accessor infers a type';
    ok $result->is_atom && $result->name eq 'Str',
        'TestPkg::find(1)->name infers as Str (not Any)';
};

subtest 'infer accessor on alias-typed variable' => sub {
    # When a function returns Alias("Person"), the variable inherits the alias,
    # and ->age should still resolve through alias resolution.
    my $source = <<'PERL';
package TestPkg;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
sub find :sig((Int) -> Person) ($id) { Person(name => "x", age => $id) }
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_all($extracted, $registry);

    my $env = +{
        variables => +{},
        functions => +{},
        registry  => $registry,
        package   => 'main',
    };

    # TestPkg::find(1)->age should infer as Int
    my $ppi = PPI::Document->new(\q{ TestPkg::find(1)->age });
    my $word = $ppi->find_first('PPI::Token::Word');
    my $result = Typist::Static::Infer->infer_expr($word, $env);
    ok $result, 'cross-package accessor infers a type';
    ok $result->is_atom && $result->name eq 'Int',
        'TestPkg::find(1)->age infers as Int';
};

# ── Static type checking: struct constructor ──────

use Typist::Static::Analyzer;

# Helper: analyze source, return TypeMismatch diagnostics
sub _struct_type_errors {
    my ($source) = @_;
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@* ];
}

subtest 'struct constructor: correct usage — no errors' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
sub test :sig(() -> Void) () {
    my $p = Person(name => "Alice", age => 30);
}
PERL
    is scalar @$errs, 0, 'no type errors for correct struct constructor call';
};

subtest 'struct constructor: field type mismatch' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
sub test :sig(() -> Void) () {
    my $p = Person(name => 42, age => 30);
}
PERL
    ok scalar @$errs >= 1, 'detects field type mismatch';
    like $errs->[0]{message}, qr/field 'name'.*Str/, 'error identifies field and expected type';
};

subtest 'struct constructor: missing required field' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
sub test :sig(() -> Void) () {
    my $p = Person(name => "Alice");
}
PERL
    ok scalar @$errs >= 1, 'detects missing required field';
    like $errs->[0]{message}, qr/missing required field 'age'/, 'error identifies missing field';
};

subtest 'struct constructor: unknown field' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
sub test :sig(() -> Void) () {
    my $p = Person(name => "Alice", age => 30, hair => "brown");
}
PERL
    ok scalar @$errs >= 1, 'detects unknown field';
    like $errs->[0]{message}, qr/unknown field 'hair'/, 'error identifies unknown field';
};

subtest 'struct constructor: optional field omission OK' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct Config => (host => Str, port => Int, debug => optional(Bool));
sub test :sig(() -> Void) () {
    my $c = Config(host => "localhost", port => 8080);
}
PERL
    is scalar @$errs, 0, 'no errors when optional field is omitted';
};

subtest 'struct constructor: optional field type mismatch' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct Config => (host => Str, port => Int, debug => optional(Bool));
sub test :sig(() -> Void) () {
    my $c = Config(host => "localhost", port => 8080, debug => "yes");
}
PERL
    ok scalar @$errs >= 1, 'detects optional field type mismatch';
    like $errs->[0]{message}, qr/field 'debug'.*Bool/, 'error identifies optional field';
};

subtest 'struct constructor: expression value inference' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct Person => (name => Str, age => Int);
sub test :sig(() -> Void) () {
    my $p = Person(name => "Alice", age => 1 + 2);
}
PERL
    is scalar @$errs, 0, 'no errors when expression infers correct type';
};

# ── Generic struct: extraction ──────────────────

subtest 'extractor recognizes generic struct' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct 'Pair[T, U]' => (fst => T, snd => U);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    ok exists $extracted->{structs}{Pair}, 'Pair struct extracted';

    my $info = $extracted->{structs}{Pair};
    is_deeply $info->{type_params}, ['T', 'U'], 'type params extracted';
    is $info->{fields}{fst}, 'T', 'fst field type';
    is $info->{fields}{snd}, 'U', 'snd field type';
};

# ── Generic struct: registration ────────────────

subtest 'registration creates generic struct type' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct 'Pair[T, U]' => (fst => T, snd => U);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_structs($extracted, $registry);

    my $type = $registry->lookup_type('Pair');
    ok $type, 'Pair type registered';
    ok $type->is_struct, 'is struct';
    my @tp = $type->type_params;
    is scalar @tp, 2, 'two type params';
    is $tp[0], 'T', 'first param';
    is $tp[1], 'U', 'second param';

    # Constructor registered with generics
    my $pkg = $extracted->{package};
    my $fn = $registry->lookup_function($pkg, 'Pair');
    ok $fn, 'constructor registered';
    ok $fn->{generics} && @{$fn->{generics}} == 2, 'two generics';
};

# ── Generic struct: inference ───────────────────

subtest 'infer generic struct constructor return type' => sub {
    my $source = <<'PERL';
package main;
use Typist;
use Typist::DSL;
struct 'Pair[T, U]' => (fst => T, snd => U);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_all($extracted, $registry);

    my $env = +{
        variables => +{},
        functions => +{},
        registry  => $registry,
    };

    my $ppi = PPI::Document->new(\q{ Pair(fst => 42, snd => "hi") });
    my $expr = $ppi->find_first('PPI::Token::Word');
    my $result = Typist::Static::Infer->infer_expr($expr, $env);
    ok $result, 'constructor infers a type';
    ok $result->is_struct, 'infers struct type';
    is $result->name, 'Pair', 'struct name is Pair';

    my @ta = $result->type_args;
    is scalar @ta, 2, 'two type args';
    ok $ta[0]->is_atom && $ta[0]->name eq 'Int', 'T = Int';
    ok $ta[1]->is_atom && $ta[1]->name eq 'Str', 'U = Str';
};

subtest 'infer generic struct accessor: Pair(fst => 42, snd => "hi")->fst' => sub {
    my $source = <<'PERL';
package main;
use Typist;
use Typist::DSL;
struct 'Pair[T, U]' => (fst => T, snd => U);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_all($extracted, $registry);

    my $env = +{
        variables => +{},
        functions => +{},
        registry  => $registry,
    };

    my $ppi = PPI::Document->new(\q{ Pair(fst => 42, snd => "hi")->fst });
    my $word = $ppi->find_first('PPI::Token::Word');
    my $result = Typist::Static::Infer->infer_expr($word, $env);
    ok $result, 'chained accessor infers a type';
    ok $result->is_atom && $result->name eq 'Int',
        'Pair(...)->fst infers as Int';
};

subtest 'infer generic struct accessor on variable' => sub {
    my $source = <<'PERL';
package main;
use Typist;
use Typist::DSL;
struct 'Pair[T, U]' => (fst => T, snd => U);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_all($extracted, $registry);

    # Simulate: $p has type Pair[Int, Str]
    my $pair_type = $registry->lookup_type('Pair');
    my $concrete = $pair_type->instantiate(
        Typist::Type::Atom->new('Int'), Typist::Type::Atom->new('Str'),
    );
    my $env = +{
        variables => +{ '$p' => $concrete },
        functions => +{},
        registry  => $registry,
    };

    my $ppi = PPI::Document->new(\q{ $p->snd });
    my $sym = $ppi->find_first('PPI::Token::Symbol');
    my $result = Typist::Static::Infer->infer_expr($sym, $env);
    ok $result, 'accessor on typed variable infers';
    ok $result->is_atom && $result->name eq 'Str',
        '$p->snd infers as Str';
};

# ── Generic struct: type checking ───────────────

subtest 'generic struct constructor: no errors for correct usage' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct 'Pair[T, U]' => (fst => T, snd => U);
sub test :sig(() -> Void) () {
    my $p = Pair(fst => 42, snd => "hello");
}
PERL
    is scalar @$errs, 0, 'no type errors for correct generic struct construction';
};

subtest 'generic struct constructor: missing required field' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct 'Pair[T, U]' => (fst => T, snd => U);
sub test :sig(() -> Void) () {
    my $p = Pair(fst => 42);
}
PERL
    ok scalar @$errs >= 1, 'detects missing required field';
    like $errs->[0]{message}, qr/missing required field 'snd'/, 'error identifies missing field';
};

subtest 'generic struct constructor: unknown field' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct 'Pair[T, U]' => (fst => T, snd => U);
sub test :sig(() -> Void) () {
    my $p = Pair(fst => 42, snd => "hi", extra => 1);
}
PERL
    ok scalar @$errs >= 1, 'detects unknown field';
    like $errs->[0]{message}, qr/unknown field 'extra'/, 'error identifies unknown field';
};

# ── Generic struct: subtyping ───────────────────

subtest 'generic struct subtype: Pair[Int, Str] <: Pair[Int, Str]' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct 'Pair[T, U]' => (fst => T, snd => U);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_structs($extracted, $registry);

    my $pair = $registry->lookup_type('Pair');
    my $a = $pair->instantiate(Typist::Type::Atom->new('Int'), Typist::Type::Atom->new('Str'));
    my $b = $pair->instantiate(Typist::Type::Atom->new('Int'), Typist::Type::Atom->new('Str'));
    ok Typist::Subtype->is_subtype($a, $b, registry => $registry),
        'Pair[Int, Str] <: Pair[Int, Str]';
};

subtest 'generic struct subtype: Pair[Int, Str] </: Pair[Int, Int]' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct 'Pair[T, U]' => (fst => T, snd => U);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_structs($extracted, $registry);

    my $pair = $registry->lookup_type('Pair');
    my $a = $pair->instantiate(Typist::Type::Atom->new('Int'), Typist::Type::Atom->new('Str'));
    my $b = $pair->instantiate(Typist::Type::Atom->new('Int'), Typist::Type::Atom->new('Int'));
    ok !Typist::Subtype->is_subtype($a, $b, registry => $registry),
        'Pair[Int, Str] </: Pair[Int, Int]';
};

use Typist::Type::Atom;

subtest 'generic struct subtype: covariance (Bool <: Int)' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct 'Box[T]' => (val => T);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_structs($extracted, $registry);

    my $box = $registry->lookup_type('Box');
    my $box_bool = $box->instantiate(Typist::Type::Atom->new('Bool'));
    my $box_int  = $box->instantiate(Typist::Type::Atom->new('Int'));
    ok Typist::Subtype->is_subtype($box_bool, $box_int, registry => $registry),
        'Box[Bool] <: Box[Int] (covariance)';
};

# ── Generic struct: Param ↔ Struct in static analysis ──

subtest 'generic struct: return type annotation matches constructor' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct 'Box[T]' => (val => T);
sub make_box :sig(() -> Box[Int]) () {
    Box(val => 42);
}
PERL
    is scalar @$errs, 0,
        'no TypeMismatch for generic struct return type (Param ↔ Struct)';
};

subtest 'generic struct: return type mismatch detected' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct 'Box[T]' => (val => T);
sub make_box :sig(() -> Box[Str]) () {
    Box(val => 42);
}
PERL
    ok scalar @$errs >= 1, 'detects type mismatch: Box[Str] vs Box[Int]';
};

subtest 'generic struct: param type annotation matches argument' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct 'Box[T]' => (val => T);
sub unbox :sig((Box[Int]) -> Int) ($b) {
    $b->val;
}
PERL
    is scalar @$errs, 0,
        'no TypeMismatch for generic struct param type';
};

# ── Bounded generic struct: extraction ──────────

subtest 'extractor preserves type_param_specs with bounds' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct 'NumBox[T: Num]' => (val => T);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    ok exists $extracted->{structs}{NumBox}, 'NumBox struct extracted';

    my $info = $extracted->{structs}{NumBox};
    is_deeply $info->{type_params}, ['T'], 'type_params = [T]';
    is_deeply $info->{type_param_specs}, ['T: Num'], 'type_param_specs preserved';
};

subtest 'extractor preserves mixed bounded/unbounded specs' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct 'Mixed[T: Num, U]' => (val => T, extra => U);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $info = $extracted->{structs}{Mixed};
    is_deeply $info->{type_params}, ['T', 'U'], 'type_params names';
    is_deeply $info->{type_param_specs}, ['T: Num', 'U'], 'mixed specs preserved';
};

# ── Bounded generic struct: registration ────────

subtest 'registration creates bounded generics for constructor' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct 'NumBox[T: Num]' => (val => T);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_structs($extracted, $registry);

    my $pkg = $extracted->{package};
    my $fn = $registry->lookup_function($pkg, 'NumBox');
    ok $fn, 'NumBox constructor registered';
    ok $fn->{generics} && @{$fn->{generics}} == 1, 'one generic';
    is $fn->{generics}[0]{name}, 'T', 'generic name is T';
    is $fn->{generics}[0]{bound_expr}, 'Num', 'bound_expr is Num';
};

subtest 'registration: bounded struct to_string shows bounds' => sub {
    my $source = <<'PERL';
use Typist;
use Typist::DSL;
struct 'NumBox[T: Num]' => (val => T);
PERL
    my $extracted = Typist::Static::Extractor->extract($source);
    my $registry  = Typist::Registry->new;
    Typist::Static::Registration->register_structs($extracted, $registry);

    my $type = $registry->lookup_type('NumBox');
    like $type->to_string, qr/NumBox\[T: Num\]/, 'to_string shows bounds';
};

# ── Bounded generic struct: static type checking ──

subtest 'bounded struct: Int satisfies Num — no errors' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct 'NumBox[T: Num]' => (val => T);
sub test :sig(() -> Void) () {
    my $nb = NumBox(val => 42);
}
PERL
    is scalar @$errs, 0, 'no errors when bound satisfied';
};

subtest 'bounded struct: Str violates Num bound' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
struct 'NumBox[T: Num]' => (val => T);
sub test :sig(() -> Void) () {
    my $nb = NumBox(val => "hello");
}
PERL
    ok scalar @$errs >= 1, 'detects bound violation';
    like $errs->[0]{message}, qr/does not satisfy bound Num/, 'error message mentions bound';
};

subtest 'bounded struct: typeclass constraint violation' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
typeclass Show2 => (show2 => '(T) -> Str');
instance Show2 => Int, (show2 => sub ($x) { "$x" });
struct 'ShowBox2[T: Show2]' => (val => T);
sub test :sig(() -> Void) () {
    my $sb = ShowBox2(val => "hello");
}
PERL
    ok scalar @$errs >= 1, 'detects typeclass constraint violation';
    like $errs->[0]{message}, qr/no instance of Show2 for/, 'error mentions missing instance';
};

subtest 'bounded struct: typeclass constraint satisfied' => sub {
    my $errs = _struct_type_errors(<<'PERL');
package main;
use Typist;
use Typist::DSL;
typeclass Show3 => (show3 => '(T) -> Str');
instance Show3 => Int, (show3 => sub ($x) { "$x" });
struct 'ShowBox3[T: Show3]' => (val => T);
sub test :sig(() -> Void) () {
    my $sb = ShowBox3(val => 42);
}
PERL
    is scalar @$errs, 0, 'no errors when typeclass constraint satisfied';
};

done_testing;
