use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Find references for a function ──────────────

subtest 'references finds all occurrences of function name' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :Type((Str) -> Str) ($name) {
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
sub get_age :Type(( ) -> Age) () { 42 }
sub set_age :Type((Age) -> Void) ($a) { }
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
sub helper :Type((Int) -> Int) ($n) { $n + 1 }
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

# ── Word boundary precision ─────────────────────

subtest 'references respects word boundaries' => sub {
    my $source = <<'PERL';
use v5.40;
sub foo :Type(( ) -> Int) () { 1 }
sub foobar :Type(( ) -> Int) () { 2 }
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

done_testing;
