use v5.40;
use Test::More;
use lib 'lib';

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Typist::LSP::Workspace;

# ── Workspace scan ───────────────────────────────

subtest 'scans directory for typedefs' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    # Create a .pm file with typedef
    open my $fh, '>', "$dir/lib/MyTypes.pm" or die;
    print $fh <<'PERL';
package MyTypes;
use v5.40;
typedef UserId => 'Int';
typedef Email  => 'Str';
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my @names = $ws->all_typedef_names;
    ok((grep { $_ eq 'UserId' } @names), 'UserId found');
    ok((grep { $_ eq 'Email'  } @names), 'Email found');

    # Registry should resolve these
    my $type = $ws->registry->lookup_type('UserId');
    ok $type, 'UserId resolves';
    ok $type->is_atom, 'UserId is Atom';
    is $type->name, 'Int', 'UserId is Int';
};

# ── Incremental update ──────────────────────────

subtest 'update_file refreshes workspace' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Types.pm" or die;
    print $fh <<'PERL';
package Types;
typedef Count => 'Int';
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws->registry->has_alias('Count'), 'Count initially present';

    # Update file with different typedef
    $ws->update_file("$dir/lib/Types.pm", <<'PERL');
package Types;
typedef Score => 'Num';
1;
PERL

    my @names = $ws->all_typedef_names;
    ok((grep { $_ eq 'Score' } @names), 'Score added');
    ok(!(grep { $_ eq 'Count' } @names), 'Count removed');
};

# ── Multiple files ───────────────────────────────

subtest 'multiple files contribute typedefs' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh1, '>', "$dir/lib/A.pm" or die;
    print $fh1 "package A;\ntypedef Name => 'Str';\n1;\n";
    close $fh1;

    open my $fh2, '>', "$dir/lib/B.pm" or die;
    print $fh2 "package B;\ntypedef Age => 'Int';\n1;\n";
    close $fh2;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    my @names = $ws->all_typedef_names;

    ok((grep { $_ eq 'Name' } @names), 'Name from A.pm');
    ok((grep { $_ eq 'Age'  } @names), 'Age from B.pm');
};

done_testing;
