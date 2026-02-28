use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Extractor;

# ── Newtype extraction ──────────────────────────

subtest 'extracts newtypes' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package MyApp;
use v5.40;
newtype UserId  => 'Str';
newtype OrderId => 'Int';
PERL

    my $newtypes = $result->{newtypes};
    ok exists $newtypes->{UserId},  'UserId newtype found';
    ok exists $newtypes->{OrderId}, 'OrderId newtype found';
    is $newtypes->{UserId}{inner_expr},  'Str', 'UserId inner is Str';
    is $newtypes->{OrderId}{inner_expr}, 'Int', 'OrderId inner is Int';
    ok $newtypes->{UserId}{line} > 0, 'UserId has line number';
};

subtest 'newtype with complex inner type' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
newtype Email => 'Str';
PERL

    is $result->{newtypes}{Email}{inner_expr}, 'Str', 'Email inner expr';
};

# ── Effect extraction ───────────────────────────

subtest 'extracts effects' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package MyApp;
use v5.40;
effect Console => +{
    readLine  => 'CodeRef[-> Str]',
    writeLine => 'CodeRef[Str -> Void]',
};
effect Log => +{
    log => 'CodeRef[Str -> Void]',
};
PERL

    my $effects = $result->{effects};
    ok exists $effects->{Console}, 'Console effect found';
    ok exists $effects->{Log},     'Log effect found';
    ok $effects->{Console}{line} > 0, 'Console has line number';
};

# ── TypeClass extraction ────────────────────────

subtest 'extracts typeclasses with var_spec and method_names' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package MyApp;
use v5.40;
typeclass Show => T, +{
    show => Func(T, returns => Str),
};

typeclass Eq => T, +{
    eq => Func(T, T, returns => Bool),
};
PERL

    my $tc = $result->{typeclasses};
    ok exists $tc->{Show}, 'Show typeclass found';
    ok exists $tc->{Eq},   'Eq typeclass found';
    ok $tc->{Show}{line} > 0, 'Show has line number';

    is $tc->{Show}{var_spec}, 'T', 'Show var_spec is T';
    is_deeply $tc->{Show}{method_names}, ['show'], 'Show method_names';
    is $tc->{Eq}{var_spec}, 'T', 'Eq var_spec is T';
    is_deeply $tc->{Eq}{method_names}, ['eq'], 'Eq method_names';
};

subtest 'extracts typeclass with superclass constraint' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
typeclass Ord => 'T: Eq', +{
    compare => Func(T, T, returns => Int),
};
PERL

    my $tc = $result->{typeclasses};
    ok exists $tc->{Ord}, 'Ord typeclass found';
    is $tc->{Ord}{var_spec}, 'T: Eq', 'Ord var_spec includes superclass';
    is_deeply $tc->{Ord}{method_names}, ['compare'], 'Ord method_names';
};

subtest 'extracts typeclass with multiple superclass constraints' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
typeclass Printable => 'T: Show + Eq', +{
    display => Func(T, returns => Str),
};
PERL

    my $tc = $result->{typeclasses};
    ok exists $tc->{Printable}, 'Printable typeclass found';
    is $tc->{Printable}{var_spec}, 'T: Show + Eq', 'multiple superclass var_spec';
    is_deeply $tc->{Printable}{method_names}, ['display'], 'Printable method_names';
};

# ── Combined extraction ─────────────────────────

subtest 'full file with all type definitions' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package Shop::Types;
use v5.40;

typedef Price    => 'Int';
typedef Quantity => 'Int';

newtype ProductId => 'Str';
newtype OrderId   => 'Int';

effect Logger => +{
    log => 'CodeRef[Str -> Void]',
};

typeclass Printable => T, +{
    display => Func(T, returns => Str),
};

sub add :Type((Int, Int) -> Int) ($a, $b) {
    $a + $b;
}

1;
PERL

    is $result->{package}, 'Shop::Types', 'package name';
    ok exists $result->{aliases}{Price},      'typedef Price found';
    ok exists $result->{aliases}{Quantity},    'typedef Quantity found';
    ok exists $result->{newtypes}{ProductId},  'newtype ProductId found';
    ok exists $result->{newtypes}{OrderId},    'newtype OrderId found';
    ok exists $result->{effects}{Logger},      'effect Logger found';
    ok exists $result->{typeclasses}{Printable}, 'typeclass Printable found';
    ok exists $result->{functions}{add},       'function add found';
};

# ── Declare extraction ─────────────────────────

subtest 'extracts declare with bare name (builtin)' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package MyApp;
use v5.40;
declare say => '(Str) -> Void !Eff(Console)';
PERL

    my $declares = $result->{declares};
    ok exists $declares->{say}, 'declare say found';
    is $declares->{say}{package},   'CORE', 'bare name maps to CORE';
    is $declares->{say}{func_name}, 'say',  'func_name is say';
    is $declares->{say}{type_expr}, '(Str) -> Void !Eff(Console)', 'type_expr captured';
    ok $declares->{say}{line} > 0, 'has line number';
};

subtest 'extracts declare with qualified name' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
declare 'JSON::encode_json' => '(Any) -> Str';
PERL

    my $declares = $result->{declares};
    ok exists $declares->{'JSON::encode_json'}, 'qualified declare found';
    is $declares->{'JSON::encode_json'}{package},   'JSON',        'package is JSON';
    is $declares->{'JSON::encode_json'}{func_name}, 'encode_json', 'func_name extracted';
    is $declares->{'JSON::encode_json'}{type_expr}, '(Any) -> Str', 'type_expr captured';
};

subtest 'extracts declare with generics' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
use v5.40;
declare 'List::Util::first' => '<T>(CodeRef, ArrayRef[T]) -> T';
PERL

    my $declares = $result->{declares};
    ok exists $declares->{'List::Util::first'}, 'generic declare found';
    is $declares->{'List::Util::first'}{type_expr},
       '<T>(CodeRef, ArrayRef[T]) -> T', 'generic type_expr preserved';
};

# ── Edge cases ──────────────────────────────────

subtest 'empty source has empty collections' => sub {
    my $result = Typist::Static::Extractor->extract('use v5.40;');

    is_deeply $result->{newtypes},    +{}, 'no newtypes';
    is_deeply $result->{effects},     +{}, 'no effects';
    is_deeply $result->{typeclasses}, +{}, 'no typeclasses';
};

done_testing;
