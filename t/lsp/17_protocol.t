use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Hover on effect with protocol ────────────

subtest 'hover shows protocol on effect' => sub {
    my $source = <<'PERL';
use v5.40;
effect DB => qw/None Connected/ => +{
    connect => protocol('(Str) -> Void', 'None -> Connected'),
    query   => protocol('(Str) -> Str',  'Connected -> Connected'),
};
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///proto.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/hover', +{
            textDocument => +{ uri => 'file:///proto.pm' },
            position => +{ line => 1, character => 7 },  # on 'DB'
        }),
    ));

    my ($hover) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hover, 'got hover response';
    ok $hover->{result}, 'hover has result';
    like $hover->{result}{contents}{value}, qr/effect DB/, 'shows effect DB';
    like $hover->{result}{contents}{value}, qr/\x{2192}/, 'shows transition arrows';
};

# ── InlayHints with protocol state ────────────

subtest 'inlay hints include protocol state' => sub {
    my $source = <<'PERL';
use v5.40;
effect DB => qw/None Connected Authed/ => +{
    connect => protocol('(Str) -> Void',      'None -> Connected'),
    auth    => protocol('(Str, Str) -> Void', 'Connected -> Authed'),
};

sub setup :sig(() -> Void ![DB<None -> Authed>]) () {
    DB::connect("localhost");
    DB::auth("user", "pass");
}
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///proto_hint.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/inlayHint', +{
            textDocument => +{ uri => 'file:///proto_hint.pm' },
            range => +{
                start => +{ line => 0, character => 0 },
                end   => +{ line => 15, character => 0 },
            },
        }),
    ));

    my ($hints_resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $hints_resp, 'got inlay hints response';
    my $hints = $hints_resp->{result} // [];
    my @proto_hints = grep { ($_->{label} // '') =~ /\[/ } @$hints;
    ok @proto_hints > 0, 'protocol state hints present';
};

done_testing;
