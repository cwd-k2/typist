use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use File::Path qw(make_path);
use File::Temp qw(tempdir);

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Rename a function ───────────────────────────

subtest 'rename produces WorkspaceEdit for all occurrences' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :sig((Str) -> Str) ($name) {
    return "hello $name";
}
greet("world");
my $x = greet("alice");
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/rename', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on 'greet'
            newName  => 'salute',
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got rename response';
    my $edit = $resp->{result};
    ok $edit, 'has result';
    ok $edit->{changes}, 'has changes';
    ok $edit->{changes}{'file:///test.pm'}, 'has edits for test.pm';

    my $edits = $edit->{changes}{'file:///test.pm'};
    is scalar @$edits, 3, '3 text edits (decl + 2 calls)';

    for my $e (@$edits) {
        is $e->{newText}, 'salute', 'newText is salute';
    }

    # Verify edit positions
    my @lines = sort map { $_->{range}{start}{line} } @$edits;
    is_deeply \@lines, [1, 4, 5], 'edits on correct lines';
};

# ── Rename across multiple open documents ────────

subtest 'rename spans multiple open documents' => sub {
    my $source_a = <<'PERL';
use v5.40;
sub helper :sig((Int) -> Int) ($n) { $n + 1 }
PERL

    my $source_b = <<'PERL';
use v5.40;
my $y = helper(10);
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///a.pm', text => $source_a, version => 1 },
        }),
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///b.pm', text => $source_b, version => 1 },
        }),
        lsp_request(2, 'textDocument/rename', +{
            textDocument => +{ uri => 'file:///a.pm' },
            position => +{ line => 1, character => 5 },  # on 'helper'
            newName  => 'assist',
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got rename response';
    my $edit = $resp->{result};
    ok $edit && $edit->{changes}, 'has changes';

    my @uris = sort keys %{$edit->{changes}};
    ok scalar(@uris) >= 2, 'edits span at least 2 files';
    ok $edit->{changes}{'file:///a.pm'}, 'has edits for a.pm';
    ok $edit->{changes}{'file:///b.pm'}, 'has edits for b.pm';

    for my $uri (@uris) {
        for my $e (@{$edit->{changes}{$uri}}) {
            is $e->{newText}, 'assist', "newText is assist in $uri";
        }
    }
};

subtest 'rename includes closed workspace files via index' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Helper.pm" or die;
    print $fh <<'PERL';
package Helper;
use v5.40;
sub helper :sig((Int) -> Int) ($n) { $n + 1 }
1;
PERL
    close $fh;

    my $source = <<'PERL';
package App;
use v5.40;
use Helper;
my $y = helper(10);
PERL

    my @results = run_session(
        lsp_request(1, 'initialize', +{ rootUri => "file://$dir" }),
        lsp_notification('initialized'),
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///app.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/rename', +{
            textDocument => +{ uri => 'file:///app.pm' },
            position => +{ line => 3, character => 8 },
            newName  => 'assist',
        }),
        lsp_request(99, 'shutdown'),
        lsp_notification('exit'),
    );

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got rename response';
    my $edit = $resp->{result};
    ok $edit && $edit->{changes}, 'has changes';
    ok $edit->{changes}{'file:///app.pm'}, 'has open-file edit';
    ok $edit->{changes}{"file://$dir/lib/Helper.pm"}, 'has closed workspace file edit';
};

subtest 'rename excludes similarly-prefixed names in closed workspace files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh1, '>', "$dir/lib/Helper.pm" or die;
    print $fh1 <<'PERL';
package Helper;
use v5.40;
sub helper :sig((Int) -> Int) ($n) { $n + 1 }
1;
PERL
    close $fh1;

    open my $fh2, '>', "$dir/lib/Other.pm" or die;
    print $fh2 <<'PERL';
package Other;
use v5.40;
sub helper_extra :sig((Int) -> Int) ($n) { $n + 2 }
1;
PERL
    close $fh2;

    my $source = <<'PERL';
package App;
use v5.40;
use Helper;
my $y = helper(10);
PERL

    my @results = run_session(
        lsp_request(1, 'initialize', +{ rootUri => "file://$dir" }),
        lsp_notification('initialized'),
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///app.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/rename', +{
            textDocument => +{ uri => 'file:///app.pm' },
            position => +{ line => 3, character => 8 },
            newName  => 'assist',
        }),
        lsp_request(99, 'shutdown'),
        lsp_notification('exit'),
    );

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got rename response';
    my $edit = $resp->{result};
    ok $edit && $edit->{changes}, 'has changes';
    ok $edit->{changes}{'file:///app.pm'}, 'renames open-file occurrence';
    ok $edit->{changes}{"file://$dir/lib/Helper.pm"}, 'renames exact closed-file match';
    ok !$edit->{changes}{"file://$dir/lib/Other.pm"}, 'does not rename similarly-prefixed closed-file symbol';
};

# ── Rename returns null for unknown position ─────

subtest 'rename returns null when cursor is on whitespace' => sub {
    my $source = <<'PERL';
use v5.40;
my $x = 42;
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/rename', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 7 },  # on '=' (space before 42)
            newName  => 'whatever',
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got rename response';
    ok !$resp->{result}, 'result is null for non-word position';
};

# ── Rename respects word boundaries ──────────────

subtest 'rename does not affect similarly-prefixed names' => sub {
    my $source = <<'PERL';
use v5.40;
sub foo :sig(( ) -> Int) () { 1 }
sub foobar :sig(( ) -> Int) () { 2 }
foo();
foobar();
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/rename', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on 'foo'
            newName  => 'bar',
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got rename response';
    my $edits = $resp->{result}{changes}{'file:///test.pm'};
    is scalar @$edits, 2, 'only 2 edits for foo (not foobar)';

    my @lines = sort map { $_->{range}{start}{line} } @$edits;
    is_deeply \@lines, [1, 3], 'edits on lines 1 and 3 only';
};

# ── Scoped rename for variables ──────────────────

subtest 'rename variable only in its scope' => sub {
    my $source = <<'PERL';
use v5.40;
sub foo :sig((Int) -> Int) ($x) {
    $x + 1;
}
sub bar :sig((Int) -> Int) ($x) {
    $x * 2;
}
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/rename', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 5 },  # on $x inside foo
            newName  => '$y',
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got rename response';
    my $edits = $resp->{result}{changes}{'file:///test.pm'};
    ok $edits, 'has edits';

    # Should NOT rename $x in bar()
    my @lines = sort map { $_->{range}{start}{line} } @$edits;
    ok !grep({ $_ >= 4 } @lines), 'no edits in bar() scope';
};

done_testing;
