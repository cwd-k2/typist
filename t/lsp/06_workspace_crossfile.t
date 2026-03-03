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

done_testing;
