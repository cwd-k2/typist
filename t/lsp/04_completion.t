use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session lsp_request lsp_notification init_shutdown_wrap);

# ── Completion inside :Type( ─────────────────────

subtest 'completion inside :Type(' => sub {
    my $source = "use v5.40;\nsub foo :Type(";

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/completion', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => length('sub foo :Type(') },
        }),
    ));

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    ok $comp->{result}{items}, 'has items';

    my @labels = map { $_->{label} } @{$comp->{result}{items}};
    ok((grep { $_ eq 'Int' }      @labels), 'Int in completions');
    ok((grep { $_ eq 'Str' }      @labels), 'Str in completions');
    ok((grep { $_ eq 'ArrayRef' } @labels), 'ArrayRef in completions');
};

# ── Completion inside :Type(< ─────────────────

subtest 'completion inside :Type(<' => sub {
    my $source = "use v5.40;\nsub foo :Type(<";

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/completion', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => length('sub foo :Type(<') },
        }),
    ));

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    ok $comp->{result}{items}, 'has items';

    my @labels = map { $_->{label} } @{$comp->{result}{items}};
    ok((grep { $_ eq 'T' } @labels), 'T in completions');
    ok((grep { $_ eq 'U' } @labels), 'U in completions');
    # Should not include primitives
    ok(!(grep { $_ eq 'Int' } @labels), 'Int not in generic completions');
};

# ── No completion outside type context ───────────

subtest 'no completion outside type context' => sub {
    my $source = "use v5.40;\nmy \$x = ";

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/completion', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => length('my $x = ') },
        }),
    ));

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    is scalar @{$comp->{result}{items}}, 0, 'no completions outside type context';
};

# ── Completion inside :Type(... ! ────────────────

subtest 'completion inside :Type(... !' => sub {
    my $source = "use v5.40;\nsub foo :Type(() -> Void ! ";

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/completion', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => length('sub foo :Type(() -> Void ! ') },
        }),
    ));

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    # Should return items (even if empty, no primitives in effect context)
    ok $comp->{result}{items}, 'has items array';
    # Should NOT include type primitives
    my @labels = map { $_->{label} } @{$comp->{result}{items}};
    ok(!(grep { $_ eq 'Int' } @labels), 'Int not in effect completions');
    ok(!(grep { $_ eq 'Str' } @labels), 'Str not in effect completions');
};

# ── Completion inside :Type(<T: — constraint context ──

subtest 'completion inside :Type(<T: ' => sub {
    my $source = "use v5.40;\nsub foo :Type(<T: ";

    my @results = run_session(init_shutdown_wrap(
        lsp_notification('textDocument/didOpen', +{
            textDocument => +{ uri => 'file:///test.pm', text => $source, version => 1 },
        }),
        lsp_request(2, 'textDocument/completion', +{
            textDocument => +{ uri => 'file:///test.pm' },
            position => +{ line => 1, character => length('sub foo :Type(<T: ') },
        }),
    ));

    my ($comp) = grep { defined $_->{id} && $_->{id} == 2 } @results;
    ok $comp, 'got completion response';
    ok $comp->{result}{items}, 'has items';

    # Should not include type primitives or type vars in constraint context
    my @labels = map { $_->{label} } @{$comp->{result}{items}};
    ok(!(grep { $_ eq 'Int' } @labels), 'Int not in constraint completions');
    ok(!(grep { $_ eq 'T' }   @labels), 'T not in constraint completions');
};

done_testing;
