use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Inlay hints for inferred variable ───────────

subtest 'inlayHint shows inferred type for unannotated variable' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :sig((Str) -> Str) ($name) { "Hello, $name" }
my $result = greet("Alice");
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/inlayHint', +{
            textDocument => +{ uri => 'file:///test.pm' },
            range => +{
                start => +{ line => 0, character => 0 },
                end   => +{ line => 3, character => 0 },
            },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got inlayHint response';
    my $hints = $resp->{result};
    ok ref $hints eq 'ARRAY', 'result is array';

    my ($hint) = grep { ($_->{label} // '') =~ /Str/ } @$hints;
    ok $hint, 'found hint with Str type';
    is $hint->{kind}, 1, 'kind is Type (1)';
    is $hint->{position}{line}, 2, 'hint on line 2 (0-indexed)';
    like $hint->{label}, qr/^: Str$/, 'label is ": Str"';
};

# ── No inlay hints for annotated variables ──────

subtest 'inlayHint omits annotated variables' => sub {
    my $source = <<'PERL';
use v5.40;
my $x :sig(Int) = 42;
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/inlayHint', +{
            textDocument => +{ uri => 'file:///test.pm' },
            range => +{
                start => +{ line => 0, character => 0 },
                end   => +{ line => 2, character => 0 },
            },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got inlayHint response';
    my $hints = $resp->{result};
    is scalar @$hints, 0, 'no hints for annotated variables';
};

# ── Inlay hints respect range filtering ────────

subtest 'inlayHint respects requested range' => sub {
    my $source = <<'PERL';
use v5.40;
sub greet :sig((Str) -> Str) ($name) { "Hello, $name" }
my $result = greet("Alice");
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/inlayHint', +{
            textDocument => +{ uri => 'file:///test.pm' },
            range => +{
                start => +{ line => 0, character => 0 },
                end   => +{ line => 1, character => 0 },  # only lines 0-1, not line 2
            },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got inlayHint response';
    my $hints = $resp->{result};
    is scalar @$hints, 0, 'no hints outside range';
};

# ── No inlay hints for unknown type variables ────

subtest 'inlayHint omits variables with unknown type' => sub {
    my $source = <<'PERL';
use v5.40;
my $mystery = some_unknown_thing();
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/inlayHint', +{
            textDocument => +{ uri => 'file:///test.pm' },
            range => +{
                start => +{ line => 0, character => 0 },
                end   => +{ line => 2, character => 0 },
            },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got inlayHint response';
    my $hints = $resp->{result};
    my @any_hints = grep { ($_->{label} // '') =~ /Any/ } @$hints;
    is scalar @any_hints, 0, 'no hint for unknown (Any) variables';
};

# ── Inlay hints for $_ in map block ──────────────

subtest 'inlayHint shows $_ type in map block' => sub {
    my $source = <<'PERL';
use v5.40;
my @nums :sig(ArrayRef[Int]) = (1, 2, 3);
my @doubled = map { $_ * 2 } @nums;
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/inlayHint', +{
            textDocument => +{ uri => 'file:///test.pm' },
            range => +{
                start => +{ line => 0, character => 0 },
                end   => +{ line => 4, character => 0 },
            },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got inlayHint response';
    my $hints = $resp->{result};
    # Expect $_ hint with Int type on the map line
    my @underscore_hints = grep { ($_->{label} // '') =~ /Int/ } @$hints;
    ok @underscore_hints, 'found $_ hint with Int type in map block';
};

# ── Inlay hints for handle handler params ────────

subtest 'inlayHint shows handler param types from effect operation' => sub {
    my $source = <<'PERL';
use v5.40;
effect Console => +{ writeLine => '(Str) -> Void' };
sub run :sig(() -> Void ! [Console]) () {
    handle { Console::writeLine("hello") }
        Console => +{ writeLine => sub ($msg) { say $msg } };
}
PERL

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/inlayHint', +{
            textDocument => +{ uri => 'file:///test.pm' },
            range => +{
                start => +{ line => 0, character => 0 },
                end   => +{ line => 7, character => 0 },
            },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got inlayHint response';
    my $hints = $resp->{result};
    my ($msg_hint) = grep { ($_->{label} // '') =~ /Str/ && ($_->{position}{line} // -1) == 4 } @$hints;
    ok $msg_hint, 'found $msg hint with Str type on handler line';
};

# ── Effect inlay hint position (after function name) ──

subtest 'inferred effect hint positioned after function name' => sub {
    my $source = <<'PERL';
package TestPkg;
use v5.40;
effect Console => +{ writeLine => '(Str) -> Void' };
sub greet ($name) { Console::writeLine("Hello, $name") }
PERL
    #   ^--- "sub greet" → name starts at col 5, name_col=5, len=5 → character=9

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/inlayHint', +{
            textDocument => +{ uri => 'file:///test.pm' },
            range => +{
                start => +{ line => 0, character => 0 },
                end   => +{ line => 5, character => 0 },
            },
        }),
    ));

    my ($resp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $resp, 'got inlayHint response';
    my $hints = $resp->{result};
    my ($eff_hint) = grep { ($_->{label} // '') =~ /!\[/ } @$hints;
    ok $eff_hint, 'found inferred effect hint';
    # "sub greet" at col 1: name_col=5 (1-indexed), name len=5
    # character = (5-1) + 5 = 9 (0-indexed, right after "greet")
    is $eff_hint->{position}{character}, 9, 'effect hint at end of function name';
    is $eff_hint->{position}{line}, 3, 'effect hint on function line';
    like $eff_hint->{label}, qr/Console/, 'label includes Console effect';
};

done_testing;
