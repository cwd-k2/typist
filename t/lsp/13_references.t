use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use File::Path qw(make_path);
use File::Temp qw(tempdir);

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Find references for a function ──────────────

subtest 'references finds all occurrences of function name' => sub {
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
        lsp_request(2, 'textDocument/references', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on 'greet' in declaration
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got references response';
    my $locs = $resp->{result};
    ok $locs && ref $locs eq 'ARRAY', 'result is an array';
    is scalar @$locs, 3, 'found 3 occurrences of greet (decl + 2 calls)';

    # All locations should be in the same file
    for my $loc (@$locs) {
        is $loc->{uri}, 'file:///test.pm', 'reference in correct file';
    }

    # Check lines: line 1 (decl), line 4 (first call), line 5 (second call)
    my @lines = sort map { $_->{range}{start}{line} } @$locs;
    is_deeply \@lines, [1, 4, 5], 'references on correct lines';
};

# ── Find references for a type name ──────────────

subtest 'references finds type name in annotations and typedef' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
sub get_age :sig(( ) -> Age) () { 42 }
sub set_age :sig((Age) -> Void) ($a) { }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/references', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 9 },  # on 'Age' in typedef
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got references response';
    my $locs = $resp->{result};
    ok $locs && @$locs >= 3, 'found at least 3 occurrences of Age';
};

# ── No references for unknown word ──────────────

subtest 'references returns empty for cursor on non-identifier' => sub {
    my $source = <<'PERL';
use v5.40;
my $x = 42;
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/references', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 9 },  # on '42' literal
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got references response';
    # Result may be undef or an array — either is acceptable for a literal
    my $locs = $resp->{result};
    ok !$locs || ref $locs eq 'ARRAY', 'result is null or array';
};

# ── References across multiple open documents ──

subtest 'references spans multiple open documents' => sub {
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
        lsp_request(2, 'textDocument/references', +{
            textDocument => +{ uri => 'file:///a.pm' },
            position => +{ line => 1, character => 5 },  # on 'helper' in decl
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got references response';
    my $locs = $resp->{result};
    ok $locs && @$locs >= 2, 'found references across both documents';

    my %uris = map { $_->{uri} => 1 } @$locs;
    ok $uris{'file:///a.pm'}, 'found reference in a.pm';
    ok $uris{'file:///b.pm'}, 'found reference in b.pm';
};

subtest 'references includes closed workspace files via index' => sub {
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
        lsp_request(2, 'textDocument/references', +{
            textDocument => +{ uri => 'file:///app.pm' },
            position => +{ line => 3, character => 8 },  # on helper call
        }),
        lsp_request(99, 'shutdown'),
        lsp_notification('exit'),
    );

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got references response';
    my $locs = $resp->{result};
    ok $locs && @$locs >= 2, 'found references across open and closed files';

    my %uris = map { $_->{uri} => 1 } @$locs;
    ok $uris{'file:///app.pm'}, 'found open-file reference';
    ok $uris{"file://$dir/lib/Helper.pm"}, 'found closed workspace file reference';
};

# ── Word boundary precision ─────────────────────

subtest 'references respects word boundaries' => sub {
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
        lsp_request(2, 'textDocument/references', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on 'foo' in declaration
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got references response';
    my $locs = $resp->{result};

    # Should find 'foo' on lines 1 and 3, but NOT 'foobar' on lines 2 and 4
    my @lines = sort map { $_->{range}{start}{line} } @$locs;
    ok !grep({ $_ == 2 || $_ == 4 } @lines), 'does not match foobar';
    ok scalar(@$locs) == 2, 'found exactly 2 occurrences of foo';
};

# ── Scoped references for variables ──────────────

subtest 'scoped references: $x in different functions' => sub {
    my $source = <<'PERL';
use v5.40;
sub foo :sig((Int) -> Int) ($x) {
    $x + 1;
}
sub bar :sig((Str) -> Str) ($x) {
    $x . "!";
}
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/references', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 5 },  # on $x inside foo
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got references response';
    my $locs = $resp->{result};
    ok $locs && ref $locs eq 'ARRAY', 'result is an array';

    # Should only find $x within foo (lines 1-3), not bar (lines 4-6)
    my @lines = sort map { $_->{range}{start}{line} } @$locs;
    ok !grep({ $_ >= 4 } @lines), 'no $x references from bar()';
};

subtest 'scoped references: function names remain global' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :sig((Str) -> Str) ($name) { "hi $name" }
greet("world");
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/references', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on 'greet'
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got references response';
    my $locs = $resp->{result};
    is scalar @$locs, 2, 'function name still finds all occurrences (global)';
};

done_testing;
