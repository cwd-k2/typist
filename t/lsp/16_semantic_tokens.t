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
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
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
sub greet :sig((Str) -> Str) ($name) { "Hello, $name" }
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

# ── Annotation tokenization: type names and operators ───

subtest 'annotation tokens: type names and arrow in :sig()' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
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

    # Find type tokens (index 0) for 'Int' inside the annotation
    my @type_toks = grep { $_->{type} == 0 && $_->{len} == 3 } @tokens;
    ok scalar @type_toks >= 3, 'at least 3 Int type tokens in annotation';

    # Find operator tokens (index 8) for '->'
    my @arrow_toks = grep { $_->{type} == 8 && $_->{len} == 2 } @tokens;
    ok scalar @arrow_toks >= 1, 'found -> operator token';
};

subtest 'annotation tokens: type parameters distinguished' => sub {
    my $source = <<'PERL';
use v5.40;
sub id :sig(<T>(T) -> T) ($x) { $x }
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

    # T should be typeParameter (index 1), not type (index 0)
    my @tparam_toks = grep { $_->{type} == 1 && $_->{len} == 1 } @tokens;
    ok scalar @tparam_toks >= 1, 'found T as typeParameter token';
};

subtest 'annotation tokens: effect label and bang operator' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :sig((Str) -> Void ![Console]) ($name) { }
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

    # Console should be a type token (index 0)
    my @console_toks = grep { $_->{type} == 0 && $_->{len} == 7 } @tokens;
    ok scalar @console_toks >= 1, 'found Console as type token';

    # ! should be an operator token (index 8)
    my @bang_toks = grep { $_->{type} == 8 && $_->{len} == 1 } @tokens;
    ok scalar @bang_toks >= 1, 'found ! operator token';
};

subtest 'annotation tokens: variable annotation type names' => sub {
    my $source = <<'PERL';
use v5.40;
my $x :sig(Int) = 42;
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

    # Int should be a type token (index 0) from the annotation
    my @type_toks = grep { $_->{type} == 0 && $_->{len} == 3 } @tokens;
    ok scalar @type_toks >= 1, 'found Int type token in variable annotation';
};

subtest 'effect sig string tokens: type names and operators' => sub {
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

    # writeLine should be a function token (index 3)
    my @fn_toks = grep { $_->{type} == 3 && $_->{len} == 9 } @tokens;
    ok scalar @fn_toks >= 1, 'found writeLine as function token';

    # Str should be a type token (index 0) inside the sig string
    # Source line: "effect Console => +{ writeLine => '(Str) -> Void' };"
    #              0         1         2         3         4
    #              0123456789012345678901234567890123456789012345678
    # '(Str) -> Void' — opening ' at col 34, ( at 35, S at 36
    my @str_toks = grep { $_->{type} == 0 && $_->{len} == 3 } @tokens;
    ok scalar @str_toks >= 1, 'found Str type token in effect sig string';
    my ($str_in_sig) = grep { $_->{line} == 1 && $_->{col} == 36 } @str_toks;
    ok $str_in_sig, 'Str token at exact column 36 inside sig string';

    # Void should be a type token (index 0) — V at col 44
    my @void_toks = grep { $_->{type} == 0 && $_->{len} == 4 } @tokens;
    ok scalar @void_toks >= 1, 'found Void type token in effect sig string';
    my ($void_in_sig) = grep { $_->{line} == 1 && $_->{col} == 44 } @void_toks;
    ok $void_in_sig, 'Void token at exact column 44 inside sig string';

    # -> should be an operator token (index 8) — - at col 41
    my @arrow_toks = grep { $_->{type} == 8 && $_->{len} == 2 } @tokens;
    ok scalar @arrow_toks >= 1, 'found -> operator token in effect sig string';
    my ($arrow_in_sig) = grep { $_->{line} == 1 && $_->{col} == 41 } @arrow_toks;
    ok $arrow_in_sig, '-> token at exact column 41 inside sig string';
};

subtest 'typeclass sig string tokens: type params and operators' => sub {
    my $source = <<'PERL';
use v5.40;
typeclass Show => T, +{ show => '(T) -> Str' };
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

    # show should be a function token (index 3)
    my @fn_toks = grep { $_->{type} == 3 && $_->{len} == 4 } @tokens;
    ok scalar @fn_toks >= 1, 'found show as function token';

    # T should be typeParameter (index 1) inside the sig string
    my @tparam_toks = grep { $_->{type} == 1 && $_->{len} == 1 } @tokens;
    ok scalar @tparam_toks >= 1, 'found T as typeParameter token in typeclass sig string';

    # Str should be a type token (index 0)
    my @str_toks = grep { $_->{type} == 0 && $_->{len} == 3 } @tokens;
    ok scalar @str_toks >= 1, 'found Str type token in typeclass sig string';

    # -> should be an operator token (index 8)
    my @arrow_toks = grep { $_->{type} == 8 && $_->{len} == 2 } @tokens;
    ok scalar @arrow_toks >= 1, 'found -> operator token in typeclass sig string';
};

subtest 'annotation tokens: lowercase row variable as typeParameter' => sub {
    my $source = <<'PERL';
use v5.40;
sub with_log :sig(<r: Row>(Str) -> Str ![Log, r]) ($msg) { $msg }
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

    # r should be typeParameter (index 1), len 1
    my @rparam_toks = grep { $_->{type} == 1 && $_->{len} == 1 } @tokens;
    ok scalar @rparam_toks >= 1, 'found r as typeParameter token';

    # Log should be a type token (index 0)
    my @log_toks = grep { $_->{type} == 0 && $_->{len} == 3 } @tokens;
    ok scalar @log_toks >= 1, 'found Log as type token';
};

# ── Datatype variant type strings ─────────────────

subtest 'datatype variant type strings get type tokens' => sub {
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

    # Int should appear as type tokens (index 0, len 3) inside variant specs
    my @int_toks = grep { $_->{type} == 0 && $_->{len} == 3 } @tokens;
    # Shape(5) + at least 3 Int occurrences from '(Int)' and '(Int, Int)'
    ok scalar @int_toks >= 3, 'at least 3 type tokens for Int in variant specs';

    # Verify Int tokens appear on the variant lines (line 2 and 3)
    my @variant_ints = grep { $_->{line} >= 2 } @int_toks;
    ok scalar @variant_ints >= 3, 'Int tokens on variant lines';
};

# ── Parameterized datatype type parameter tokens ──

subtest 'parameterized datatype type params in variant specs' => sub {
    my $source = <<'PERL';
use v5.40;
datatype 'Option[T]' => Some => '(T)', None => '()';
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

    # T inside '(T)' should be typeParameter (index 1)
    my @tparam_toks = grep { $_->{type} == 1 && $_->{len} == 1 } @tokens;
    ok scalar @tparam_toks >= 1, 'found T as typeParameter in variant spec';
};

# ── Struct field type string tokens ───────────────

subtest 'struct field type strings get type tokens' => sub {
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

    # Int should appear as type tokens (index 0) from field type strings
    my @int_toks = grep { $_->{type} == 0 && $_->{len} == 3 && $_->{line} == 1 } @tokens;
    ok scalar @int_toks >= 2, 'at least 2 Int type tokens in struct field types';
};

# ── Punctuation tokens in annotation ──────────────

subtest 'annotation tokens: punctuation as operator tokens' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :sig((Int, Str) -> Void) ($a, $b) { }
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

    # Source: "sub greet :sig((Int, Str) -> Void) ($a, $b) { }"
    #  :sig( at col 10, content starts at col 15
    #  (  at col 15   → operator
    #  I  at col 16   → type (Int)
    #  ,  at col 19   → operator
    #  S  at col 21   → type (Str)
    #  )  at col 24   → operator
    #  -> at col 26   → operator
    #  V  at col 29   → type (Void)

    # Operator tokens (index 8) on line 1
    my @ops = grep { $_->{type} == 8 && $_->{line} == 1 } @tokens;

    # Expect: ( , ) -> at minimum
    ok scalar @ops >= 4, 'at least 4 operator tokens (parens, comma, arrow)';

    # Check parentheses: len 1, operator
    my @parens = grep { $_->{len} == 1 && ($_->{col} == 15 || $_->{col} == 24) } @ops;
    is scalar @parens, 2, 'found ( and ) operator tokens';

    # Check comma
    my ($comma) = grep { $_->{col} == 19 && $_->{len} == 1 } @ops;
    ok $comma, 'found comma operator token at col 19';

    # Check arrow
    my ($arrow) = grep { $_->{col} == 26 && $_->{len} == 2 } @ops;
    ok $arrow, 'found -> operator token at col 26';
};

subtest 'annotation tokens: variadic ... as operator' => sub {
    my $source = <<'PERL';
use v5.40;
sub variadic :sig((Int, ...Str) -> Void) ($x, @rest) { }
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

    # Find ... operator token (index 8, len 3)
    my @dots = grep { $_->{type} == 8 && $_->{len} == 3 } @tokens;
    ok scalar @dots >= 1, 'found ... variadic operator token';
};

subtest 'annotation tokens: brackets and angle brackets' => sub {
    my $source = <<'PERL';
use v5.40;
sub poly :sig(<T>(ArrayRef[T]) -> T ![IO]) ($arr) { $arr->[0] }
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

    # Operator tokens on line 1
    my @ops = grep { $_->{type} == 8 && $_->{line} == 1 } @tokens;

    # Should include < > [ ] ( ) -> ! — at least 8 operators
    ok scalar @ops >= 8, "at least 8 operator tokens for <T>(ArrayRef[T]) -> T ![IO]: got " . scalar @ops;

    # Check angle brackets: len 1
    my @angles = grep { $_->{len} == 1 } @ops;
    ok scalar @angles >= 6, 'single-char operators include < > [ ] ( ) etc.';
};

# ── Literal type tokens ──────────────────────────

subtest 'annotation tokens: numeric literals' => sub {
    my $source = <<'PERL';
use v5.40;
sub flag :sig((0 | 1) -> Str) ($f) { $f ? "yes" : "no" }
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

    # number tokens (index 9)
    my @nums = grep { $_->{type} == 9 && $_->{line} == 1 } @tokens;
    is scalar @nums, 2, 'found 2 numeric literal tokens (0 and 1)';

    # | operator between them (index 8)
    my @pipes = grep { $_->{type} == 8 && $_->{line} == 1 && $_->{len} == 1 } @tokens;
    ok((grep { $_->{col} > $nums[0]{col} && $_->{col} < $nums[1]{col} } @pipes),
        'found | operator between numeric literals');
};

subtest 'annotation tokens: string literals' => sub {
    my $source = <<'PERL';
use v5.40;
my $s :sig("ok" | "error") = "ok";
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

    # string tokens (index 10)
    my @strs = grep { $_->{type} == 10 && $_->{line} == 1 } @tokens;
    is scalar @strs, 2, 'found 2 string literal tokens ("ok" and "error")';
    is $strs[0]{len}, 4, '"ok" token length is 4 (including quotes)';
    is $strs[1]{len}, 7, '"error" token length is 7 (including quotes)';

    # | operator between them
    my @pipes = grep { $_->{type} == 8 && $_->{line} == 1 && $_->{len} == 1 } @tokens;
    ok scalar @pipes >= 1, 'found | operator between string literals';
};

subtest 'annotation tokens: mixed literal union' => sub {
    my $source = <<'PERL';
use v5.40;
sub code :sig((0 | 1 | "unknown") -> Void) ($c) { }
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

    # 2 numbers (0, 1) and 1 string ("unknown")
    my @nums = grep { $_->{type} == 9 && $_->{line} == 1 } @tokens;
    my @strs = grep { $_->{type} == 10 && $_->{line} == 1 } @tokens;
    is scalar @nums, 2, '2 numeric literal tokens';
    is scalar @strs, 1, '1 string literal token';

    # 2 pipe operators
    my @pipes = grep { $_->{type} == 8 && $_->{line} == 1 && $_->{len} == 1 } @tokens;
    ok scalar @pipes >= 4, 'pipe and paren operators present';
};

subtest 'datatype variant specs: numeric literals in quoted strings' => sub {
    my $source = <<'PERL';
use v5.40;
datatype Bit => Zero => '(0)', One => '(1)';
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

    # number tokens (index 9) from '(0)' and '(1)'
    my @nums = grep { $_->{type} == 9 } @tokens;
    is scalar @nums, 2, 'found 2 numeric literal tokens in variant specs';
};

# ── Typedef value string tokens ───────────────────

subtest 'typedef value string gets type and literal tokens' => sub {
    my $source = <<'PERL';
use v5.40;
typedef DiscountPct => '0 | 5 | 10 | 15 | 20';
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

    # number tokens (index 9) for 0, 5, 10, 15, 20
    my @nums = grep { $_->{type} == 9 && $_->{line} == 1 } @tokens;
    is scalar @nums, 5, 'found 5 numeric literal tokens in typedef value string';

    # | operator tokens (index 8) between the literals
    my @pipes = grep { $_->{type} == 8 && $_->{line} == 1 && $_->{len} == 1 } @tokens;
    ok scalar @pipes >= 4, 'at least 4 pipe operator tokens';
};

subtest 'typedef value string: type name tokens' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Result => 'Int | Str';
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

    # Int and Str should be type tokens (index 0) from the value string
    my @type_toks = grep { $_->{type} == 0 && $_->{line} == 1 } @tokens;
    # Result (definition) + Int + Str = at least 3
    ok scalar @type_toks >= 3, 'at least 3 type tokens (Result + Int + Str)';

    # | operator
    my @pipes = grep { $_->{type} == 8 && $_->{line} == 1 && $_->{len} == 1 } @tokens;
    ok scalar @pipes >= 1, 'found | operator in typedef value string';
};

# ── Semantic tokens for declare ────────────────

subtest 'semantic tokens for bare declare' => sub {
    my $source = <<'PERL';
use v5.40;
declare say => '(Str) -> Void';
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

    # keyword 'declare' (type index 4, len 7)
    my ($kw) = grep { $_->{type} == 4 && $_->{len} == 7 } @tokens;
    ok $kw, 'found declare keyword';
    is $kw->{line}, 1, 'declare keyword on line 1';

    # function name 'say' (type index 3)
    my ($fn) = grep { $_->{type} == 3 && $_->{len} == 3 } @tokens;
    ok $fn, 'found say as function token';

    # Type tokens: Str and Void
    my @type_toks = grep { $_->{type} == 0 && $_->{line} == 1 } @tokens;
    ok scalar @type_toks >= 2, 'at least 2 type tokens (Str, Void)';

    # Arrow operator
    my @arrows = grep { $_->{type} == 8 && $_->{len} == 2 && $_->{line} == 1 } @tokens;
    ok scalar @arrows >= 1, 'found -> operator token';
};

subtest 'semantic tokens for qualified declare' => sub {
    my $source = <<'PERL';
use v5.40;
declare 'JSON::encode_json' => '(Any) -> Str';
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

    # keyword 'declare'
    my ($kw) = grep { $_->{type} == 4 && $_->{len} == 7 } @tokens;
    ok $kw, 'found declare keyword';

    # function name 'encode_json' (bare word match from func_name)
    my ($fn) = grep { $_->{type} == 3 && $_->{len} == 11 } @tokens;
    ok $fn, 'found encode_json as function token';

    # Type tokens: Any and Str inside '(Any) -> Str'
    my @type_toks = grep { $_->{type} == 0 && $_->{line} == 1 } @tokens;
    ok scalar @type_toks >= 2, 'at least 2 type tokens (Any, Str)';

    # Ensure 'JSON' from the quoted name is NOT tokenized as a type
    my @json_toks = grep { $_->{type} == 0 && $_->{len} == 4 } @type_toks;
    is scalar @json_toks, 0, 'JSON in quoted name is not tokenized as type';
};

subtest 'semantic tokens for generic declare' => sub {
    my $source = <<'PERL';
use v5.40;
declare 'List::Util::first' => '<T>(CodeRef, ArrayRef[T]) -> T';
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

    # T should be typeParameter (index 1) — appears in <T>, (…T), and -> T
    my @tparam_toks = grep { $_->{type} == 1 && $_->{len} == 1 } @tokens;
    ok scalar @tparam_toks >= 3, 'found T as typeParameter token (at least 3 occurrences)';

    # CodeRef and ArrayRef as type tokens (index 0)
    my @coderef = grep { $_->{type} == 0 && $_->{len} == 7 } @tokens;
    ok scalar @coderef >= 1, 'found CodeRef as type token';
    my @arrayref = grep { $_->{type} == 0 && $_->{len} == 8 } @tokens;
    ok scalar @arrayref >= 1, 'found ArrayRef as type token';

    # Ensure 'List' and 'Util' from the quoted name are NOT type tokens
    my @list_toks = grep { $_->{type} == 0 && $_->{len} == 4 && $_->{line} == 1 } @tokens;
    is scalar @list_toks, 0, 'List in quoted name is not tokenized as type';
};

# ── Keywords without extraction: instance, handle, match ──

subtest 'semantic tokens for instance keyword' => sub {
    my $source = <<'PERL';
use v5.40;
typeclass Show => T, +{ show => '(T) -> Str' };
instance Show => Int, +{ show => sub :sig((Int) -> Str) ($x) { "$x" } };
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

    # 'instance' keyword on line 2 (0-indexed), len 8
    my @inst_kw = grep { $_->{type} == 4 && $_->{len} == 8 && $_->{line} == 2 } @tokens;
    ok scalar @inst_kw >= 1, 'found instance keyword token on line 2';
    is $inst_kw[0]{col}, 0, 'instance keyword at column 0';
};

subtest 'semantic tokens for handle keyword' => sub {
    my $source = <<'PERL';
use v5.40;
sub run :sig(() -> Str ![Console]) () {
    handle { Console::writeLine("hi"); "done" } Console => +{
        writeLine => sub ($msg) { }
    };
}
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

    # 'handle' keyword, len 6
    my @handle_kw = grep { $_->{type} == 4 && $_->{len} == 6 } @tokens;
    ok scalar @handle_kw >= 1, 'found handle keyword token';
};

subtest 'handle expression: effect name and handler op tokens' => sub {
    my $source = <<'PERL';
use v5.40;
effect Console => +{ writeLine => '(Str) -> Void' };
sub run :sig(() -> Str ![Console]) () {
    handle { Console::writeLine("hi"); "done" } Console => +{
        writeLine => sub ($msg) { }
    };
}
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

    # Line 3 (0-indexed): handle { ... } Console => +{
    # The 'Console' after '}' should be enum (type 6)
    my @eff_names = grep { $_->{type} == 6 && $_->{line} == 3 && $_->{len} == 7 } @tokens;
    ok scalar @eff_names >= 1, 'Console in handler section colored as enum';

    # Line 4 (0-indexed): writeLine => sub ($msg) { }
    # 'writeLine' should be function (type 3)
    my @op_names = grep { $_->{type} == 3 && $_->{line} == 4 && $_->{len} == 9 } @tokens;
    ok scalar @op_names >= 1, 'writeLine in handler hash colored as function';
};

subtest 'semantic tokens for match keyword' => sub {
    my $source = <<'PERL';
use v5.40;
sub describe :sig((Int) -> Str) ($x) {
    match $x, 0 => sub { "zero" }, _ => sub { "other" };
}
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

    # 'match' keyword, len 5
    my @match_kw = grep { $_->{type} == 4 && $_->{len} == 5 } @tokens;
    ok scalar @match_kw >= 1, 'found match keyword token';
};

# ── Usage-site tokens for constructors ─────────

subtest 'usage-site tokens: datatype constructor' => sub {
    my $source = <<'PERL';
use v5.40;
datatype Option => Some => '(Int)', None => '()';
my $val = Some(42);
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

    # Some on line 2 (usage) should be enumMember (index 7)
    my @usage_some = grep { $_->{type} == 7 && $_->{line} == 2 && $_->{len} == 4 } @tokens;
    ok scalar @usage_some >= 1, 'Some usage token as enumMember on line 2';
};

subtest 'usage-site tokens: effect op' => sub {
    my $source = <<'PERL';
use v5.40;
effect Console => +{ writeLine => '(Str) -> Void' };
Console::writeLine("hello");
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

    # Console on line 2 should be enum (index 6)
    my @eff_name = grep { $_->{type} == 6 && $_->{line} == 2 && $_->{len} == 7 } @tokens;
    ok scalar @eff_name >= 1, 'Console usage token as enum on line 2';

    # writeLine on line 2 should be function (index 3)
    my @op_name = grep { $_->{type} == 3 && $_->{line} == 2 && $_->{len} == 9 } @tokens;
    ok scalar @op_name >= 1, 'writeLine usage token as function on line 2';
};

# ── Instance declaration typeclass/type tokens ──

subtest 'instance declaration: typeclass and type tokens' => sub {
    my $source = <<'PERL';
use v5.40;
typeclass Show => T, +{ show => '(T) -> Str' };
instance Show => Int, +{ show => sub :sig((Int) -> Str) ($x) { "$x" } };
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

    # 'Show' on line 2 (instance decl) should be class (index 5)
    # Source: "instance Show => Int, +{ show => sub :sig((Int) -> Str) ($x) { "$x" } };"
    #          01234567890
    #          instance Show => ...
    #                   ^-- col 9
    my @show_class = grep { $_->{type} == 5 && $_->{line} == 2 && $_->{len} == 4 } @tokens;
    ok scalar @show_class >= 1, 'Show as class token on instance line';

    # 'Int' on line 2 should be type (index 0) from instance type_expr
    # "instance Show => Int, ..."
    #                   ^-- col 17
    my @int_type = grep { $_->{type} == 0 && $_->{line} == 2 && $_->{len} == 3 } @tokens;
    ok scalar @int_type >= 1, 'Int as type token on instance line';
};

subtest 'instance declaration: multi-typeclass tokens' => sub {
    my $source = <<'PERL';
use v5.40;
typeclass Show => T, +{ show => '(T) -> Str' };
typeclass Eq   => T, +{ eq   => '(T, T) -> Bool' };
instance 'Show, Eq' => Int, +{ show => sub ($x) { "$x" }, eq => sub ($a, $b) { $a == $b } };
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

    # Both Show and Eq on line 3 should be class (index 5)
    my @class_toks = grep { $_->{type} == 5 && $_->{line} == 3 } @tokens;
    ok scalar @class_toks >= 2, 'both Show and Eq as class tokens on instance line';

    # Int on line 3 should be type (index 0)
    my @int_type = grep { $_->{type} == 0 && $_->{line} == 3 && $_->{len} == 3 } @tokens;
    ok scalar @int_type >= 1, 'Int as type token on multi-typeclass instance line';
};

# ── scoped effect string tokenization ──────────

subtest 'scoped effect string gets type tokens' => sub {
    my $source = <<'PERL';
package ScopedTok;
use v5.40;
effect 'State[S]' => +{ get => '() -> S', put => '(S) -> Void' };
my $counter = scoped 'State[Int]';
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

    # Line 3 (0-indexed): my $counter = scoped 'State[Int]';
    # 'scoped' is keyword, 'State' and 'Int' inside the string should be type tokens
    my @line3_types = grep { $_->{type} == 0 && $_->{line} == 3 } @tokens;
    ok scalar @line3_types >= 2, 'at least 2 type tokens on scoped line (State + Int)'
        or diag explain \@tokens;

    # State should be type (index 0), 5 chars
    my ($state_tok) = grep { $_->{len} == 5 } @line3_types;
    ok $state_tok, 'found State type token (5 chars)';

    # Int should be type (index 0), 3 chars
    my ($int_tok) = grep { $_->{len} == 3 } @line3_types;
    ok $int_tok, 'found Int type token (3 chars)';
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
