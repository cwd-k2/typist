use v5.40;
use Test::More;
use lib 'lib';

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Typist::LSP::Workspace;

# ── Newtypes across files ────────────────────────

subtest 'workspace indexes newtypes' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Types.pm" or die;
    print $fh <<'PERL';
package Types;
use v5.40;
newtype UserId  => 'Str';
newtype OrderId => 'Int';
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    # Newtypes should appear in all_typedef_names
    my @names = $ws->all_typedef_names;
    ok((grep { $_ eq 'UserId'  } @names), 'UserId in typedef names');
    ok((grep { $_ eq 'OrderId' } @names), 'OrderId in typedef names');

    # Registry should have newtype objects
    my $uid = $ws->registry->lookup_newtype('UserId');
    ok $uid, 'UserId newtype registered';
    is $uid->name, 'UserId', 'UserId name matches';
};

# ── Effects across files ─────────────────────────

subtest 'workspace indexes effects' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Effects.pm" or die;
    print $fh <<'PERL';
package Effects;
use v5.40;
effect Console => +{
    readLine => 'CodeRef[-> Str]',
};
effect Logger => +{
    log => 'CodeRef[Str -> Void]',
};
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    ok $ws->registry->lookup_effect('Console'), 'Console effect registered';
    ok $ws->registry->lookup_effect('Logger'),  'Logger effect registered';
};

# ── Cross-file type resolution ───────────────────

subtest 'workspace merges types from multiple files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh1, '>', "$dir/lib/TypeDefs.pm" or die;
    print $fh1 <<'PERL';
package TypeDefs;
use v5.40;
typedef Price => 'Int';
typedef Name  => 'Str';
1;
PERL
    close $fh1;

    open my $fh2, '>', "$dir/lib/NewTypes.pm" or die;
    print $fh2 <<'PERL';
package NewTypes;
use v5.40;
newtype ProductId => 'Str';
1;
PERL
    close $fh2;

    open my $fh3, '>', "$dir/lib/Effs.pm" or die;
    print $fh3 <<'PERL';
package Effs;
use v5.40;
effect DB => +{ query => 'CodeRef[Str -> Any]' };
1;
PERL
    close $fh3;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    # All types available via single registry
    ok $ws->registry->lookup_type('Price'),         'Price alias available';
    ok $ws->registry->lookup_type('Name'),          'Name alias available';
    ok $ws->registry->lookup_newtype('ProductId'),  'ProductId newtype available';
    ok $ws->registry->lookup_effect('DB'),          'DB effect available';
};

# ── Incremental update with newtypes ────────────

subtest 'update_file refreshes newtypes' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Types.pm" or die;
    print $fh "package Types;\nnewtype Foo => 'Int';\n1;\n";
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws->registry->lookup_newtype('Foo'), 'Foo initially present';

    # Update with different newtype
    $ws->update_file("$dir/lib/Types.pm", <<'PERL');
package Types;
newtype Bar => 'Str';
1;
PERL

    my @names = $ws->all_typedef_names;
    ok((grep { $_ eq 'Bar' } @names), 'Bar added after update');
    ok(!(grep { $_ eq 'Foo' } @names), 'Foo removed after update');
    ok $ws->registry->lookup_newtype('Bar'), 'Bar newtype in registry';
};

# ── Cross-file instance resolution ───────────────

subtest 'cross-file typeclass + instance resolution' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    # File A: typeclass definition
    open my $fh1, '>', "$dir/lib/Classes.pm" or die;
    print $fh1 <<'PERL';
package Classes;
use v5.40;
typeclass Show => T, +{
    show => '(T) -> Str',
};
1;
PERL
    close $fh1;

    # File B: instance declaration
    open my $fh2, '>', "$dir/lib/Instances.pm" or die;
    print $fh2 <<'PERL';
package Instances;
use v5.40;
instance Show => Int, +{
    show => sub ($x) { "$x" },
};
1;
PERL
    close $fh2;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    # Typeclass should be registered
    ok $ws->registry->has_typeclass('Show'), 'Show typeclass registered';

    # Instance should be resolvable
    require Typist::Parser;
    my $int_type = Typist::Parser->parse('Int');
    my $inst = $ws->registry->resolve_instance('Show', $int_type);
    ok $inst, 'Show instance for Int resolved';
    is $inst->type_expr, 'Int', 'resolved instance type_expr is Int';
};

subtest 'update_file replaces instances' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    # Typeclass definition
    open my $fh1, '>', "$dir/lib/Classes.pm" or die;
    print $fh1 <<'PERL';
package Classes;
use v5.40;
typeclass Eq => T, +{
    eq => '(T, T) -> Bool',
};
1;
PERL
    close $fh1;

    # Initial instance: Eq for Int
    open my $fh2, '>', "$dir/lib/Impls.pm" or die;
    print $fh2 <<'PERL';
package Impls;
use v5.40;
instance Eq => Int, +{
    eq => sub ($a, $b) { $a == $b },
};
1;
PERL
    close $fh2;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    require Typist::Parser;
    my $int_type = Typist::Parser->parse('Int');
    my $str_type = Typist::Parser->parse('Str');

    ok $ws->registry->resolve_instance('Eq', $int_type),  'Eq Int initially present';
    ok !$ws->registry->resolve_instance('Eq', $str_type), 'Eq Str initially absent';

    # Update: replace Int instance with Str instance
    $ws->update_file("$dir/lib/Impls.pm", <<'PERL');
package Impls;
use v5.40;
instance Eq => Str, +{
    eq => sub ($a, $b) { $a eq $b },
};
1;
PERL

    ok !$ws->registry->resolve_instance('Eq', $int_type), 'Eq Int removed after update';
    ok $ws->registry->resolve_instance('Eq', $str_type),  'Eq Str present after update';
};

# ── Type object ghost elimination (Phase 3) ─────

subtest 'cross-file function sig has params_expr and returns_expr' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Funcs.pm" or die;
    print $fh <<'PERL';
package Funcs;
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    my $sig = $ws->registry->lookup_function('Funcs', 'add');
    ok $sig, 'add function registered';
    is_deeply $sig->{params_expr}, ['Int', 'Int'], 'params_expr preserved';
    is $sig->{returns_expr}, 'Int', 'returns_expr preserved';
};

subtest 'cross-file declare sig has params_expr and returns_expr' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Decls.pm" or die;
    print $fh <<'PERL';
package Decls;
use v5.40;
declare 'Some::remote_fn' => '(Str, Int) -> Bool';
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    my $sig = $ws->registry->lookup_function('Some', 'remote_fn');
    ok $sig, 'remote_fn declared function registered';
    is_deeply $sig->{params_expr}, ['Str', 'Int'], 'params_expr preserved for declare';
    is $sig->{returns_expr}, 'Bool', 'returns_expr preserved for declare';
    ok $sig->{declared}, 'declared flag set';
};

subtest 'update_file removes ghost aliases' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Defs.pm" or die;
    print $fh "package Defs;\ntypedef OldName => 'Str';\n1;\n";
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws->registry->has_alias('OldName'), 'OldName alias present initially';

    # Rename alias
    $ws->update_file("$dir/lib/Defs.pm", <<'PERL');
package Defs;
typedef NewName => 'Int';
1;
PERL

    ok !$ws->registry->has_alias('OldName'), 'OldName alias removed (no ghost)';
    ok  $ws->registry->has_alias('NewName'), 'NewName alias registered';
};

subtest 'update_file removes ghost newtypes' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/NT.pm" or die;
    print $fh "package NT;\nnewtype OldId => 'Int';\n1;\n";
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws->registry->lookup_newtype('OldId'), 'OldId present initially';

    $ws->update_file("$dir/lib/NT.pm", <<'PERL');
package NT;
newtype NewId => 'Str';
1;
PERL

    ok !$ws->registry->lookup_newtype('OldId'), 'OldId newtype removed';
    ok  $ws->registry->lookup_newtype('NewId'), 'NewId newtype registered';
};

subtest 'update_file removes ghost effects' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Eff.pm" or die;
    print $fh <<'PERL';
package Eff;
use v5.40;
effect OldEffect => +{ op1 => '(Str) -> Void' };
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws->registry->lookup_effect('OldEffect'), 'OldEffect present initially';

    $ws->update_file("$dir/lib/Eff.pm", <<'PERL');
package Eff;
use v5.40;
effect NewEffect => +{ op2 => '(Int) -> Str' };
1;
PERL

    ok !$ws->registry->lookup_effect('OldEffect'), 'OldEffect removed';
    ok  $ws->registry->lookup_effect('NewEffect'), 'NewEffect registered';
};

subtest 'update_file removes ghost typeclasses' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/TC.pm" or die;
    print $fh <<'PERL';
package TC;
use v5.40;
typeclass OldClass => T, +{ method1 => '(T) -> Str' };
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws->registry->has_typeclass('OldClass'), 'OldClass present initially';

    $ws->update_file("$dir/lib/TC.pm", <<'PERL');
package TC;
use v5.40;
typeclass NewClass => T, +{ method2 => '(T) -> Int' };
1;
PERL

    ok !$ws->registry->has_typeclass('OldClass'), 'OldClass removed';
    ok  $ws->registry->has_typeclass('NewClass'), 'NewClass registered';
};

subtest 'update_file removes ghost structs and methods' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Structs.pm" or die;
    print $fh <<'PERL';
package Structs;
use v5.40;
struct OldStruct => (name => 'Str', age => 'Int');
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws->registry->lookup_struct('OldStruct'), 'OldStruct present initially';
    ok $ws->registry->lookup_method('Typist::Struct::OldStruct', 'name'), 'accessor name present';
    ok $ws->registry->lookup_function('OldStruct', 'derive'), 'derive function present';

    $ws->update_file("$dir/lib/Structs.pm", <<'PERL');
package Structs;
use v5.40;
struct NewStruct => (title => 'Str');
1;
PERL

    ok !$ws->registry->lookup_struct('OldStruct'), 'OldStruct struct removed';
    ok !$ws->registry->lookup_method('Typist::Struct::OldStruct', 'name'), 'old accessor removed';
    ok !$ws->registry->lookup_function('OldStruct', 'derive'), 'old derive removed';
    ok  $ws->registry->lookup_struct('NewStruct'), 'NewStruct registered';
    ok  $ws->registry->lookup_method('Typist::Struct::NewStruct', 'title'), 'new accessor present';
};

subtest 'update_file removes ghost datatypes' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/DT.pm" or die;
    print $fh <<'PERL';
package DT;
use v5.40;
datatype OldColor => Red => '()', Green => '()', Blue => '()';
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws->registry->lookup_datatype('OldColor'), 'OldColor present initially';

    $ws->update_file("$dir/lib/DT.pm", <<'PERL');
package DT;
use v5.40;
datatype Shape => Circle => '(Int)', Square => '(Int)';
1;
PERL

    ok !$ws->registry->lookup_datatype('OldColor'), 'OldColor datatype removed';
    ok  $ws->registry->lookup_datatype('Shape'),    'Shape datatype registered';
};

done_testing;
