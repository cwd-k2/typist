use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Document symbols for mixed declarations ─────

subtest 'documentSymbol returns all declaration kinds' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
newtype UserId => Int;
effect Console => {};
sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }
my $x :sig(Str) = "hello";
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/documentSymbol', +{
            textDocument => +{ uri => 'file:///test.pm' },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got documentSymbol response';
    my $symbols = $resp->{result};
    ok ref $symbols eq 'ARRAY', 'result is array';

    # Check we have the expected symbols (no parameters)
    my %by_name = map { $_->{name} => $_ } @$symbols;

    ok $by_name{Age},      'typedef Age present';
    is $by_name{Age}{kind}, 5, 'typedef has Class kind';
    is $by_name{Age}{detail}, 'Int', 'typedef detail shows type';

    ok $by_name{UserId},   'newtype UserId present';
    is $by_name{UserId}{kind}, 5, 'newtype has Class kind';

    ok $by_name{Console},  'effect Console present';
    is $by_name{Console}{kind}, 14, 'effect has Namespace kind';

    ok $by_name{add},      'function add present';
    is $by_name{add}{kind}, 12, 'function has Function kind';
    like $by_name{add}{detail}, qr/\(Int, Int\) -> Int/, 'function detail shows signature';

    ok $by_name{'$x'},     'variable $x present';
    is $by_name{'$x'}{kind}, 13, 'variable has Variable kind';

    # Parameters should be excluded
    ok !$by_name{'$a'}, 'parameter $a excluded';
    ok !$by_name{'$b'}, 'parameter $b excluded';
};

# ── Document symbols include line positions ─────

subtest 'documentSymbol has correct positions' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :sig((Str) -> Str) ($name) { "Hello, $name" }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/documentSymbol', +{
            textDocument => +{ uri => 'file:///test.pm' },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    my $symbols = $resp->{result};
    my ($greet) = grep { $_->{name} eq 'greet' } @$symbols;

    ok $greet, 'greet symbol found';
    is $greet->{range}{start}{line}, 1, 'range starts on line 1 (0-indexed)';
    ok $greet->{selectionRange}, 'has selectionRange';
};

# ── Document symbols include datatype ────────────

subtest 'documentSymbol includes datatype' => sub {
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
        lsp_request(2, 'textDocument/documentSymbol', +{
            textDocument => +{ uri => 'file:///test.pm' },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    my $symbols = $resp->{result};
    my ($shape) = grep { $_->{name} eq 'Shape' } @$symbols;

    ok $shape, 'datatype Shape present';
    is $shape->{kind}, 10, 'datatype has Enum kind (10)';
    like $shape->{detail}, qr/Circle/, 'detail mentions Circle variant';

    # Constructor symbols should appear as functions
    my ($circle) = grep { $_->{name} eq 'Circle' } @$symbols;
    ok $circle, 'constructor Circle present as symbol';
    is $circle->{kind}, 12, 'constructor has Function kind (12)';
    like $circle->{detail}, qr/\(Int\) -> Shape/, 'constructor detail shows (Int) -> Shape';

    my ($rect) = grep { $_->{name} eq 'Rectangle' } @$symbols;
    ok $rect, 'constructor Rectangle present as symbol';
    is $rect->{kind}, 12, 'constructor has Function kind (12)';
    like $rect->{detail}, qr/\(Int, Int\) -> Shape/, 'constructor detail shows (Int, Int) -> Shape';
};

done_testing;
