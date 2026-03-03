use v5.40;
use Test::More;
use lib 'lib';

use Typist::Registry;
use Typist::Parser;

# ── unregister_alias ─────────────────────────────

subtest 'unregister_alias removes alias and resolved cache' => sub {
    my $r = Typist::Registry->new;
    $r->define_alias('Name', 'Str');

    ok $r->has_alias('Name'), 'alias exists before unregister';
    my $type = $r->lookup_type('Name');
    ok $type, 'alias resolves before unregister';

    $r->unregister_alias('Name');

    ok !exists $r->{aliases}{Name}, 'alias removed from aliases';
    ok !exists $r->{resolved}{Name}, 'alias removed from resolved cache';
};

# ── unregister_newtype ───────────────────────────

subtest 'unregister_newtype removes newtype' => sub {
    my $r = Typist::Registry->new;
    my $inner = Typist::Parser->parse('Int');
    require Typist::Type::Newtype;
    my $nt = Typist::Type::Newtype->new('UserId', $inner);
    $r->register_newtype('UserId', $nt);

    ok $r->lookup_newtype('UserId'), 'newtype exists before unregister';

    $r->unregister_newtype('UserId');

    ok !$r->lookup_newtype('UserId'), 'newtype removed after unregister';
};

# ── unregister_datatype ──────────────────────────

subtest 'unregister_datatype removes datatype' => sub {
    my $r = Typist::Registry->new;
    require Typist::Type::Data;
    my $dt = Typist::Type::Data->new('Color', +{
        Red   => [],
        Green => [],
        Blue  => [],
    });
    $r->register_datatype('Color', $dt);

    ok $r->lookup_datatype('Color'), 'datatype exists before unregister';

    $r->unregister_datatype('Color');

    ok !$r->lookup_datatype('Color'), 'datatype removed after unregister';
};

# ── unregister_type (struct) ─────────────────────

subtest 'unregister_type removes struct' => sub {
    my $r = Typist::Registry->new;
    require Typist::Type::Record;
    require Typist::Type::Struct;
    my $record = Typist::Type::Record->from_parts(
        required => +{ name => Typist::Parser->parse('Str') },
    );
    my $st = Typist::Type::Struct->new(
        name    => 'Person',
        record  => $record,
        package => 'Typist::Struct::Person',
    );
    $r->register_type('Person', $st);

    ok $r->lookup_struct('Person'), 'struct exists before unregister';

    $r->unregister_type('Person');

    ok !$r->lookup_struct('Person'), 'struct removed after unregister';
};

# ── unregister_effect ────────────────────────────

subtest 'unregister_effect removes effect' => sub {
    my $r = Typist::Registry->new;
    require Typist::Effect;
    my $eff = Typist::Effect->new(
        name       => 'Console',
        operations => +{ writeLine => '(Str) -> Void' },
    );
    $r->register_effect('Console', $eff);

    ok $r->lookup_effect('Console'), 'effect exists before unregister';
    ok $r->is_effect_label('Console'), 'effect label exists before unregister';

    $r->unregister_effect('Console');

    ok !$r->lookup_effect('Console'), 'effect removed after unregister';
    ok !$r->is_effect_label('Console'), 'effect label gone after unregister';
};

# ── unregister_typeclass ─────────────────────────

subtest 'unregister_typeclass removes typeclass' => sub {
    my $r = Typist::Registry->new;
    require Typist::TypeClass;
    my $def = Typist::TypeClass->new_class(
        name    => 'Show',
        var     => 'T',
        methods => +{ show => '(T) -> Str' },
    );
    $r->register_typeclass('Show', $def);

    ok $r->has_typeclass('Show'), 'typeclass exists before unregister';
    ok $r->lookup_typeclass('Show'), 'typeclass resolves before unregister';

    $r->unregister_typeclass('Show');

    ok !$r->has_typeclass('Show'), 'typeclass gone after unregister';
    ok !$r->lookup_typeclass('Show'), 'typeclass lookup returns undef';
};

# ── unregister_method ────────────────────────────

subtest 'unregister_method removes method' => sub {
    my $r = Typist::Registry->new;
    $r->register_method('Typist::Struct::Person', 'name', +{
        params  => [],
        returns => Typist::Parser->parse('Str'),
    });

    ok $r->lookup_method('Typist::Struct::Person', 'name'), 'method exists before unregister';

    $r->unregister_method('Typist::Struct::Person', 'name');

    ok !$r->lookup_method('Typist::Struct::Person', 'name'), 'method removed after unregister';
};

# ── idempotent unregister ────────────────────────

subtest 'unregister on nonexistent entry is safe' => sub {
    my $r = Typist::Registry->new;

    # None of these should die
    eval { $r->unregister_alias('NoSuch') };
    ok !$@, 'unregister_alias on missing is safe';

    eval { $r->unregister_newtype('NoSuch') };
    ok !$@, 'unregister_newtype on missing is safe';

    eval { $r->unregister_datatype('NoSuch') };
    ok !$@, 'unregister_datatype on missing is safe';

    eval { $r->unregister_type('NoSuch') };
    ok !$@, 'unregister_type on missing is safe';

    eval { $r->unregister_effect('NoSuch') };
    ok !$@, 'unregister_effect on missing is safe';

    eval { $r->unregister_typeclass('NoSuch') };
    ok !$@, 'unregister_typeclass on missing is safe';

    eval { $r->unregister_method('Pkg', 'NoSuch') };
    ok !$@, 'unregister_method on missing is safe';
};

done_testing;
