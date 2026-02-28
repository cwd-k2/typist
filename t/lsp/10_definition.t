use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Definition of same-file function ──────────

subtest 'definition jumps to function declaration' => sub {
    my $source = <<'PERL';
use v5.40;
sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }
my $result = add(1, 2);
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/definition', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 2, character => 15 },  # on 'add' in call
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got definition response';
    ok $resp->{result}, 'has result';
    is $resp->{result}{uri}, 'file:///test.pm', 'same file URI';
    is $resp->{result}{range}{start}{line}, 1, 'points to declaration line';
};

# ── Definition of typedef ────────────────────

subtest 'definition jumps to typedef' => sub {
    my $source = <<'PERL';
use v5.40;
typedef Age => 'Int';
sub get_age :Type(( ) -> Age) () { 42 }
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/definition', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 10 },  # on 'Age' in typedef line
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got definition response';
    ok $resp->{result}, 'has result';
    is $resp->{result}{range}{start}{line}, 1, 'points to typedef line';
};

# ── No definition for unknown word ──────────

subtest 'definition returns null for unknown symbol' => sub {
    my $source = <<'PERL';
use v5.40;
say "hello";
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/definition', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => 5 },  # on "hello"
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got definition response';
    ok !$resp->{result}, 'result is null for unknown symbol';
};

done_testing;
