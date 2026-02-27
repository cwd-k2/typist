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

done_testing;
