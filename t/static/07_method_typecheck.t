use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;
use Typist::Static::Extractor;
use Typist::Registry;

# Helper: analyze source, return diagnostics of kind TypeMismatch
sub type_errors ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@* ];
}

# Helper: analyze source, return diagnostics of kind ArityMismatch
sub arity_errors ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq 'ArityMismatch' } $result->{diagnostics}->@* ];
}

# ── Phase 1-A: TypeChecker -> guard ─────────────

subtest 'method call: no false positive when method name matches local function' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :sig((Str) -> Str) ($name) {
    return "hello $name";
}
my $obj = bless {}, 'Foo';
$obj->greet(42);
PERL

    is scalar @$errs, 0, 'method call $obj->greet() does not trigger function greet() check';
};

subtest 'method call: function still checked normally' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub greet :sig((Str) -> Str) ($name) {
    return "hello $name";
}
greet(42);
PERL

    is scalar @$errs, 1, 'direct function call still type-checked';
    like $errs->[0]{message}, qr/Argument 1.*greet.*Str/, 'correct error message';
};

subtest 'method call: chained dereference not confused with method' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub process :sig((Int) -> Int) ($x) {
    return $x;
}
process(42);
PERL

    is scalar @$errs, 0, 'normal function call works alongside method guard';
};

subtest 'method call: arity check not triggered for method calls' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
my $obj = bless {}, 'Calc';
$obj->add(1, 2, 3);
add(1, 2);
PERL

    is scalar @$errs, 0, 'method call arity not checked; function call OK';
};

# ── Phase 1-B: Extractor is_method flag ─────────

subtest 'extractor: instance method detected ($self)' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package Greeter;
use v5.40;
sub greet :sig((Str) -> Str) ($self, $name) {
    return "hello $name";
}
PERL

    my $fn = $result->{functions}{greet};
    ok $fn, 'greet function extracted';
    ok $fn->{is_method}, 'is_method flag set';
    is $fn->{method_kind}, 'instance', 'method_kind is instance';
};

subtest 'extractor: class method detected ($class)' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package Factory;
use v5.40;
sub create :sig((Str) -> Str) ($class, $name) {
    return "new $name";
}
PERL

    my $fn = $result->{functions}{create};
    ok $fn, 'create function extracted';
    ok $fn->{is_method}, 'is_method flag set';
    is $fn->{method_kind}, 'class', 'method_kind is class';
};

subtest 'extractor: regular function not marked as method' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) {
    return $a + $b;
}
PERL

    my $fn = $result->{functions}{add};
    ok $fn, 'add function extracted';
    ok !$fn->{is_method}, 'is_method flag not set';
    is $fn->{method_kind}, undef, 'method_kind is undef';
};

subtest 'extractor: unannotated method detected' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package Widget;
use v5.40;
sub render($self, $x, $y) {
    return "$x, $y";
}
PERL

    my $fn = $result->{functions}{render};
    ok $fn, 'render function extracted';
    ok $fn->{is_method}, 'is_method flag set for unannotated method';
    is $fn->{method_kind}, 'instance', 'method_kind is instance';
    ok $fn->{unannotated}, 'still marked as unannotated';
    ok !exists $fn->{params_expr}, 'no params_expr for unannotated method';
};

subtest 'extractor: unannotated non-method keeps full arity' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
sub helper($x, $y) {
    return $x + $y;
}
PERL

    my $fn = $result->{functions}{helper};
    ok $fn, 'helper function extracted';
    ok !$fn->{is_method}, 'is_method flag not set';
    ok !exists $fn->{params_expr}, 'no params_expr for unannotated function';
};

subtest 'extractor: annotated method params_expr from :Type annotation' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package Greeter;
use v5.40;
sub greet :sig((Str) -> Str) ($self, $name) {
    return "hello $name";
}
PERL

    my $fn = $result->{functions}{greet};
    ok $fn, 'greet function extracted';
    is_deeply $fn->{params_expr}, ['Str'],
        'params_expr from :Type annotation (excludes $self)';
    is_deeply $fn->{param_names}, ['$self', '$name'],
        'param_names includes $self from signature';
};

subtest 'extractor: no-param function not a method' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
sub answer :sig(() -> Int) () {
    return 42;
}
PERL

    my $fn = $result->{functions}{answer};
    ok $fn, 'answer function extracted';
    ok !$fn->{is_method}, 'zero-param function is not a method';
};

# ── Phase 1-C: Registry register_method / lookup_method ──

subtest 'registry: register and lookup method' => sub {
    my $reg = Typist::Registry->new;

    my $sig = +{
        params  => [],
        returns => undef,
    };

    $reg->register_method('Greeter', 'greet', $sig);
    my $found = $reg->lookup_method('Greeter', 'greet');
    ok $found, 'method found after registration';
    is $found, $sig, 'same sig object returned';

    my $missing = $reg->lookup_method('Greeter', 'unknown');
    ok !$missing, 'unknown method returns undef';

    my $wrong_pkg = $reg->lookup_method('Other', 'greet');
    ok !$wrong_pkg, 'wrong package returns undef';
};

subtest 'registry: methods and functions are separate namespaces' => sub {
    my $reg = Typist::Registry->new;

    my $fn_sig = +{ params => [], returns => undef, kind => 'function' };
    my $mt_sig = +{ params => [], returns => undef, kind => 'method' };

    $reg->register_function('Pkg', 'foo', $fn_sig);
    $reg->register_method('Pkg', 'foo', $mt_sig);

    my $fn = $reg->lookup_function('Pkg', 'foo');
    my $mt = $reg->lookup_method('Pkg', 'foo');

    ok $fn, 'function found';
    ok $mt, 'method found';
    is $fn->{kind}, 'function', 'function has correct kind';
    is $mt->{kind}, 'method', 'method has correct kind';
};

subtest 'registry: reset clears methods' => sub {
    my $reg = Typist::Registry->new;
    $reg->register_method('Pkg', 'bar', +{});
    $reg->reset;
    ok !$reg->lookup_method('Pkg', 'bar'), 'method cleared after reset';
};

subtest 'registry: merge includes methods' => sub {
    my $reg1 = Typist::Registry->new;
    my $reg2 = Typist::Registry->new;

    $reg2->register_method('Pkg', 'baz', +{ test => 1 });
    $reg1->merge($reg2);

    my $found = $reg1->lookup_method('Pkg', 'baz');
    ok $found, 'method merged from other registry';
    is $found->{test}, 1, 'correct sig merged';
};

# ── Phase 1-D: Analyzer registers methods ────────

subtest 'analyzer: methods registered separately from functions' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package Calculator;
use v5.40;

sub add :sig((Int, Int) -> Int) ($self, $a, $b) {
    return $a + $b;
}

sub multiply :sig((Int, Int) -> Int) ($a, $b) {
    return $a * $b;
}
PERL

    my $reg = $result->{registry};
    ok $reg->lookup_method('Calculator', 'add'),
        'add registered as method';
    ok !$reg->lookup_function('Calculator', 'add'),
        'add not registered as function';
    ok $reg->lookup_function('Calculator', 'multiply'),
        'multiply registered as function';
    ok !$reg->lookup_method('Calculator', 'multiply'),
        'multiply not registered as method';
};

# ── Phase 2: Same-package method call type checking ──

subtest 'method call: $self->greet("hello") OK' => sub {
    my $errs = type_errors(<<'PERL');
package Greeter;
use v5.40;

sub greet :sig((Str) -> Str) ($self, $name) {
    return "Hello, $name";
}

sub run :sig(() -> Void) ($self) {
    $self->greet("hello");
}
PERL

    is scalar @$errs, 0, 'correct argument type produces no error';
};

subtest 'method call: $self->greet(42) TypeMismatch' => sub {
    my $errs = type_errors(<<'PERL');
package Greeter;
use v5.40;

sub greet :sig((Str) -> Str) ($self, $name) {
    return "Hello, $name";
}

sub run :sig(() -> Void) ($self) {
    $self->greet(42);
}
PERL

    is scalar @$errs, 1, 'type mismatch detected';
    like $errs->[0]{message}, qr/Argument 1.*greet.*Str/, 'error message mentions expected Str';
};

subtest 'method call: $self->add(1, 2) multi-param OK' => sub {
    my $errs = type_errors(<<'PERL');
package Calculator;
use v5.40;

sub add :sig((Int, Int) -> Int) ($self, $a, $b) {
    return $a + $b;
}

sub run :sig(() -> Void) ($self) {
    $self->add(1, 2);
}
PERL

    is scalar @$errs, 0, 'correct multi-param method call produces no error';
};

subtest 'method call: $self->add(1, "x") TypeMismatch on second arg' => sub {
    my $errs = type_errors(<<'PERL');
package Calculator;
use v5.40;

sub add :sig((Int, Int) -> Int) ($self, $a, $b) {
    return $a + $b;
}

sub run :sig(() -> Void) ($self) {
    $self->add(1, "x");
}
PERL

    is scalar @$errs, 1, 'type mismatch on second argument';
    like $errs->[0]{message}, qr/Argument 2.*add.*Int/, 'error points to second arg';
};

subtest 'method call: arity mismatch — too many args' => sub {
    my $errs = arity_errors(<<'PERL');
package Greeter;
use v5.40;

sub greet :sig((Str) -> Str) ($self, $name) {
    return "Hello, $name";
}

sub run :sig(() -> Void) ($self) {
    $self->greet("hello", "extra");
}
PERL

    is scalar @$errs, 1, 'arity mismatch detected';
    like $errs->[0]{message}, qr/greet.*expects 1.*got 2/, 'correct arity error message';
};

subtest 'method call: arity mismatch — too few args' => sub {
    my $errs = arity_errors(<<'PERL');
package Calculator;
use v5.40;

sub add :sig((Int, Int) -> Int) ($self, $a, $b) {
    return $a + $b;
}

sub run :sig(() -> Void) ($self) {
    $self->add(1);
}
PERL

    is scalar @$errs, 1, 'arity mismatch detected for too few args';
    like $errs->[0]{message}, qr/add.*expects 2.*got 1/, 'correct arity error message';
};

subtest 'method call: unknown method skipped (gradual typing)' => sub {
    my $errs = type_errors(<<'PERL');
package Foo;
use v5.40;

sub run :sig(() -> Void) ($self) {
    $self->unknown_method(42);
}
PERL

    is scalar @$errs, 0, 'unknown method call is silently skipped';
};

subtest 'method call: non-$self receiver skipped' => sub {
    my $errs = type_errors(<<'PERL');
package Greeter;
use v5.40;

sub greet :sig((Str) -> Str) ($self, $name) {
    return "Hello, $name";
}

sub run :sig(() -> Void) ($self) {
    my $other = bless {}, 'Greeter';
    $other->greet(42);
}
PERL

    is scalar @$errs, 0, 'non-$self receiver is not checked (Phase 2 limitation)';
};

subtest 'method call: no-arg method OK' => sub {
    my $errs = type_errors(<<'PERL');
package Widget;
use v5.40;

sub reset :sig(() -> Void) ($self) {
    return;
}

sub run :sig(() -> Void) ($self) {
    $self->reset();
}
PERL

    is scalar @$errs, 0, 'no-arg method call produces no error';
};

# ── Phase 3: Cross-Package Method Checking ───────

subtest 'cross-package: struct variable method call OK' => sub {
    my $errs = type_errors(<<'PERL');
package Person;
use v5.40;

struct Person => (name => 'Str', age => 'Int');

sub greet :sig((Str) -> Str) ($self, $msg) {
    return "$msg ${\$self->name}";
}

sub run :sig(() -> Void) () {
    my $p = Person(name => "Alice", age => 30);
    $p->greet("Hello");
}
PERL

    is scalar @$errs, 0, 'struct variable method call with correct args OK';
};

subtest 'cross-package: struct variable method type mismatch' => sub {
    my $errs = type_errors(<<'PERL');
package Person;
use v5.40;

struct Person => (name => 'Str', age => 'Int');

sub greet :sig((Str) -> Str) ($self, $msg) {
    return "$msg ${\$self->name}";
}

sub run :sig(() -> Void) () {
    my $p = Person(name => "Alice", age => 30);
    $p->greet(42);
}
PERL

    is scalar @$errs, 1, 'struct variable method call type mismatch detected';
    like $errs->[0]{message}, qr/Argument 1.*greet.*Str/, 'error message correct';
};

subtest 'cross-package: struct variable method arity mismatch' => sub {
    my $errs = arity_errors(<<'PERL');
package Person;
use v5.40;

struct Person => (name => 'Str', age => 'Int');

sub greet :sig((Str) -> Str) ($self, $msg) {
    return "$msg ${\$self->name}";
}

sub run :sig(() -> Void) () {
    my $p = Person(name => "Alice", age => 30);
    $p->greet("Hello", "extra");
}
PERL

    is scalar @$errs, 1, 'struct variable method arity mismatch detected';
    like $errs->[0]{message}, qr/greet.*expects 1.*got 2/, 'arity error message correct';
};

subtest 'cross-package: unknown typed receiver gradual skip' => sub {
    my $errs = type_errors(<<'PERL');
package Test;
use v5.40;

sub run :sig(() -> Void) () {
    my $obj = bless {}, 'Unknown';
    $obj->method(42);
}
PERL

    is scalar @$errs, 0, 'unknown typed receiver is gradual skipped';
};

# ── Phase 4: Class Method Calls ──────────────────

subtest 'class method call: Person->greet("hello") OK' => sub {
    my $errs = type_errors(<<'PERL');
package PersonCls;
use v5.40;

struct PersonCls => (name => 'Str', age => 'Int');

sub greet :sig((Str) -> Str) ($class, $msg) {
    return "Hello: $msg";
}

sub run :sig(() -> Void) () {
    PersonCls->greet("hi");
}
PERL

    is scalar @$errs, 0, 'class method call with correct args produces no error';
};

subtest 'class method call: Person->greet(42) TypeMismatch' => sub {
    my $errs = type_errors(<<'PERL');
package PersonCls2;
use v5.40;

struct PersonCls2 => (name => 'Str', age => 'Int');

sub greet :sig((Str) -> Str) ($class, $msg) {
    return "Hello: $msg";
}

sub run :sig(() -> Void) () {
    PersonCls2->greet(42);
}
PERL

    is scalar @$errs, 1, 'class method call type mismatch detected';
    like $errs->[0]{message}, qr/Argument 1.*greet.*Str/, 'error mentions expected Str';
};

subtest 'class method call: unknown class gradual skip' => sub {
    my $errs = type_errors(<<'PERL');
package TestCls;
use v5.40;

sub run :sig(() -> Void) () {
    UnknownClass->method("hello");
}
PERL

    is scalar @$errs, 0, 'unknown class method call is gradual skipped';
};

# ── Phase 5: Generic Method Instantiation ────────

subtest 'generic method: $self->transform(42) OK' => sub {
    my $errs = type_errors(<<'PERL');
package Container;
use v5.40;

sub transform :sig(<T: Num>(T) -> T) ($self, $x) {
    return $x;
}

sub run :sig(() -> Void) ($self) {
    $self->transform(42);
}
PERL

    is scalar @$errs, 0, 'generic method with correct type produces no error';
};

subtest 'generic method: $self->transform("hello") TypeMismatch' => sub {
    my $errs = type_errors(<<'PERL');
package Container2;
use v5.40;

sub transform :sig(<T: Num>(T) -> T) ($self, $x) {
    return $x;
}

sub run :sig(() -> Void) ($self) {
    $self->transform("hello");
}
PERL

    is scalar @$errs, 1, 'generic method type mismatch detected';
};

# ── Phase 6: Record Receiver ─────────────────────

subtest 'record method: accessor call OK' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
typedef PersonRec => Record(name => Str, age => Int);

sub check :sig((PersonRec) -> Void) ($p) {
    $p->name();
}
PERL

    is scalar @$errs, 0, 'record accessor call produces no error';
};

subtest 'record method: accessor with args ArityMismatch' => sub {
    my $errs = arity_errors(<<'PERL');
use v5.40;
typedef PersonRec2 => Record(name => Str, age => Int);

sub check :sig((PersonRec2) -> Void) ($p) {
    $p->name("extra");
}
PERL

    is scalar @$errs, 1, 'record accessor with args produces ArityMismatch';
    like $errs->[0]{message}, qr/accessor.*0 arguments/, 'error mentions accessor';
};

subtest 'record method: unknown field gradual skip' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
typedef PersonRec3 => Record(name => Str, age => Int);

sub check :sig((PersonRec3) -> Void) ($p) {
    $p->unknown_field();
}
PERL

    is scalar @$errs, 0, 'unknown record field is gradual skipped';
};

# ── Phase 7: Chained Method Calls ────────────────

subtest 'derive + method: PersonChain::derive then greet OK' => sub {
    my $errs = type_errors(<<'PERL');
package PersonChain;
use v5.40;

struct PersonChain => (name => 'Str', age => 'Int');

sub greet :sig((Str) -> Str) ($self, $msg) {
    return "$msg ${\$self->name}";
}

sub run :sig(() -> Void) () {
    my $p = PersonChain(name => "Alice", age => 30);
    my $q = PersonChain::derive($p, name => "Bob");
    $q->greet("hello");
}
PERL

    is scalar @$errs, 0, 'derive then method call with correct types produces no error';
};

subtest 'derive + method: type mismatch on method call' => sub {
    my $errs = type_errors(<<'PERL');
package PersonChain2;
use v5.40;

struct PersonChain2 => (name => 'Str', age => 'Int');

sub greet :sig((Str) -> Str) ($self, $msg) {
    return "$msg ${\$self->name}";
}

sub run :sig(() -> Void) () {
    my $p = PersonChain2(name => "Alice", age => 30);
    my $q = PersonChain2::derive($p, name => "Bob");
    $q->greet(42);
}
PERL

    is scalar @$errs, 1, 'type mismatch on method call after derive detected';
    like $errs->[0]{message}, qr/Argument 1.*greet.*Str/, 'error on method call';
};

subtest 'chained method: non-struct return graceful skip' => sub {
    my $errs = type_errors(<<'PERL');
package StringChain;
use v5.40;

sub get_name :sig(() -> Str) ($self) {
    return "Alice";
}

sub run :sig(() -> Void) ($self) {
    $self->get_name()->unknown_method();
}
PERL

    is scalar @$errs, 0, 'non-struct return type in chain is gradual skipped';
};

done_testing;
