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

subtest 'extracts typeclasses' => sub {
    my $result = Typist::Static::Extractor->extract(<<'PERL');
package MyApp;
use v5.40;
typeclass 'Show', 'T',
    show => 'CodeRef[T -> Str]';

typeclass 'Eq', 'T',
    eq => 'CodeRef[T, T -> Bool]';
PERL

    my $tc = $result->{typeclasses};
    ok exists $tc->{Show}, 'Show typeclass found';
    ok exists $tc->{Eq},   'Eq typeclass found';
    ok $tc->{Show}{line} > 0, 'Show has line number';
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

typeclass 'Printable', 'T',
    display => 'CodeRef[T -> Str]';

sub add :Params(Int, Int) :Returns(Int) ($a, $b) {
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

# ── Edge cases ──────────────────────────────────

subtest 'empty source has empty collections' => sub {
    my $result = Typist::Static::Extractor->extract('use v5.40;');

    is_deeply $result->{newtypes},    +{}, 'no newtypes';
    is_deeply $result->{effects},     +{}, 'no effects';
    is_deeply $result->{typeclasses}, +{}, 'no typeclasses';
};

done_testing;
