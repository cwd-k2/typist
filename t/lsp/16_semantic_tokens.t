use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Semantic tokens legend in initialize ─────────

subtest 'initialize includes semanticTokensProvider' => sub {
    my @results = run_session(init_shutdown_wrap());

    my ($init) = grep { defined $_->{id} && $_->{id} == 1 } @results;
    ok $init, 'got initialize response';

    my $cap = $init->{result}{capabilities};
    ok $cap->{semanticTokensProvider}, 'semanticTokensProvider present';

    my $legend = $cap->{semanticTokensProvider}{legend};
    ok $legend, 'legend present';
    ok ref $legend->{tokenTypes} eq 'ARRAY', 'tokenTypes is array';
    ok ref $legend->{tokenModifiers} eq 'ARRAY', 'tokenModifiers is array';
    ok scalar @{$legend->{tokenTypes}} >= 5, 'at least 5 token types';
    ok scalar @{$legend->{tokenModifiers}} >= 2, 'at least 2 token modifiers';

    is $cap->{semanticTokensProvider}{full}, 1, 'full semantic tokens enabled';
};

# ── Semantic tokens for typedef ──────────────────

subtest 'semantic tokens for typedef' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/semanticTokens/full', +{
            textDocument => +{ uri => 'file:///test.pm' },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got semanticTokens response';
    my $data = $resp->{result}{data};
    ok ref $data eq 'ARRAY', 'data is array';
    ok scalar @$data > 0, 'data is non-empty';
    is scalar(@$data) % 5, 0, 'data length is multiple of 5';

    # Decode tokens: each group of 5 is [deltaLine, deltaCol, len, type, mods]
    my @tokens = _decode_tokens($data);
    ok scalar @tokens >= 2, 'at least 2 tokens (keyword + name)';

    # Find the keyword token (type index 4 = keyword)
    my ($kw) = grep { $_->{type} == 4 } @tokens;
    ok $kw, 'found keyword token';
    is $kw->{line}, 1, 'keyword on line 1 (0-indexed)';
    is $kw->{len}, 7, 'keyword length is 7 (typedef)';

    # Find the type name token (type index 0 = type)
    my ($name) = grep { $_->{type} == 0 } @tokens;
    ok $name, 'found type name token';
    is $name->{line}, 1, 'type name on line 1';
    is $name->{len}, 3, 'type name length is 3 (Age)';
    ok $name->{mods} & 2, 'type name has definition modifier (bit 1)';
};

# ── Semantic tokens for function ─────────────────

subtest 'semantic tokens for function' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/semanticTokens/full', +{
            textDocument => +{ uri => 'file:///test.pm' },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got semanticTokens response';
    my @tokens = _decode_tokens($resp->{result}{data});

    # Find the 'sub' keyword
    my ($sub_kw) = grep { $_->{type} == 4 && $_->{len} == 3 } @tokens;
    ok $sub_kw, 'found sub keyword token';
    is $sub_kw->{line}, 1, 'sub on line 1';

    # Find the function name (type index 3 = function)
    my ($fn) = grep { $_->{type} == 3 } @tokens;
    ok $fn, 'found function name token';
    is $fn->{len}, 3, 'function name length is 3 (add)';
    ok $fn->{mods} & 2, 'function has definition modifier';
};

# ── Semantic tokens for effect ───────────────────

subtest 'semantic tokens for effect' => sub {
    my $source = <<'PERL';
use v5.40;
effect Console => +{ writeLine => '(Str) -> Void' };
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/semanticTokens/full', +{
            textDocument => +{ uri => 'file:///test.pm' },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got semanticTokens response';
    my @tokens = _decode_tokens($resp->{result}{data});

    # keyword 'effect'
    my ($kw) = grep { $_->{type} == 4 && $_->{len} == 6 } @tokens;
    ok $kw, 'found effect keyword';

    # effect name (type index 6 = enum)
    my ($name) = grep { $_->{type} == 6 } @tokens;
    ok $name, 'found effect name token (enum type)';
    is $name->{len}, 7, 'effect name length is 7 (Console)';
    ok $name->{mods} & 2, 'effect name has definition modifier';
};

# ── Semantic tokens for datatype with variants ───

subtest 'semantic tokens for datatype' => sub {
    my $source = <<'PERL';
use v5.40;
datatype Shape =>
    Circle    => '(Int)',
    Rectangle => '(Int, Int)';
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/semanticTokens/full', +{
            textDocument => +{ uri => 'file:///test.pm' },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got semanticTokens response';
    my @tokens = _decode_tokens($resp->{result}{data});

    # keyword 'datatype'
    my ($kw) = grep { $_->{type} == 4 && $_->{len} == 8 } @tokens;
    ok $kw, 'found datatype keyword';

    # datatype name (type index 0 = type)
    my ($dt_name) = grep { $_->{type} == 0 && $_->{len} == 5 } @tokens;
    ok $dt_name, 'found type name token (Shape)';
    ok $dt_name->{mods} & 2, 'type name has definition modifier';

    # variant names (type index 7 = enumMember)
    my @variants = grep { $_->{type} == 7 } @tokens;
    ok scalar @variants >= 2, 'at least 2 enumMember tokens';

    my @lens = sort map { $_->{len} } @variants;
    ok((grep { $_ == 6 } @lens), 'found Circle (len 6)');
    ok((grep { $_ == 9 } @lens), 'found Rectangle (len 9)');
};

# ── Semantic tokens for mixed declarations ───────

subtest 'semantic tokens for mixed declarations' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
newtype UserId => Int;
effect Logger => +{};
sub greet :Type((Str) -> Str) ($name) { "Hello, $name" }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/semanticTokens/full', +{
            textDocument => +{ uri => 'file:///test.pm' },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got semanticTokens response';
    my @tokens = _decode_tokens($resp->{result}{data});

    # Verify delta encoding monotonicity: lines never decrease
    my $prev_line = -1;
    my $monotonic = 1;
    for my $t (@tokens) {
        if ($t->{line} < $prev_line) {
            $monotonic = 0;
            last;
        }
        $prev_line = $t->{line};
    }
    ok $monotonic, 'decoded tokens are sorted by line';

    # Check that we have keyword tokens for each declaration kind
    my @keywords = grep { $_->{type} == 4 } @tokens;
    ok scalar @keywords >= 4, 'at least 4 keyword tokens (typedef, newtype, effect, sub)';

    # Check token types are present
    my %seen_types = map { $_->{type} => 1 } @tokens;
    ok $seen_types{0}, 'type tokens present';
    ok $seen_types{3}, 'function tokens present';
    ok $seen_types{4}, 'keyword tokens present';
    ok $seen_types{6}, 'enum (effect) tokens present';
};

# ── Empty document ───────────────────────────────

subtest 'semantic tokens for empty document' => sub {
    my $source = <<'PERL';
use v5.40;
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/semanticTokens/full', +{
            textDocument => +{ uri => 'file:///test.pm' },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got semanticTokens response';
    my $data = $resp->{result}{data};
    is scalar @$data, 0, 'no tokens for plain Perl source';
};

# ── Semantic tokens for struct declaration ────────

subtest 'semantic tokens for struct' => sub {
    my $source = <<'PERL';
use v5.40;
struct Point => (x => 'Int', y => 'Int');
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/semanticTokens/full', +{
            textDocument => +{ uri => 'file:///test.pm' },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got semanticTokens response';
    my @tokens = _decode_tokens($resp->{result}{data});

    # keyword 'struct'
    my ($kw) = grep { $_->{type} == 4 && $_->{len} == 6 } @tokens;
    ok $kw, 'found struct keyword';
    is $kw->{line}, 1, 'struct keyword on line 1';

    # struct name (type index 0 = type)
    my ($st_name) = grep { $_->{type} == 0 && $_->{len} == 5 } @tokens;
    ok $st_name, 'found type name token (Point)';
    ok $st_name->{mods} & 2, 'type name has definition modifier';

    # field names with readonly modifier (bit 2 = 4)
    my @fields = grep { $_->{type} == 2 && ($_->{mods} & 4) } @tokens;
    ok scalar @fields >= 2, 'at least 2 readonly field tokens';

    my @lens = sort map { $_->{len} } @fields;
    ok((grep { $_ == 1 } @lens), 'found field x or y (len 1)');
};

done_testing;

# ── Test Helpers ─────────────────────────────────

# Decode delta-encoded token data into a list of absolute-position hashrefs.
sub _decode_tokens ($data) {
    my @tokens;
    my ($line, $col) = (0, 0);

    for (my $i = 0; $i < @$data; $i += 5) {
        my ($dl, $dc, $len, $type, $mods) = @{$data}[$i .. $i + 4];
        if ($dl > 0) {
            $line += $dl;
            $col = $dc;
        } else {
            $col += $dc;
        }
        push @tokens, +{
            line => $line,
            col  => $col,
            len  => $len,
            type => $type,
            mods => $mods,
        };
    }

    @tokens;
}
