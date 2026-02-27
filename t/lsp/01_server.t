use v5.40;
use Test::More;
use lib 'lib', 't/lib';

use Test::Typist::LSP qw(run_session);

# ── Initialize / Shutdown lifecycle ──────────────

subtest 'initialize and shutdown' => sub {
    my @results = run_session(
        +{ jsonrpc => '2.0', id => 1, method => 'initialize', params => +{} },
        +{ jsonrpc => '2.0', method => 'initialized', params => +{} },
        +{ jsonrpc => '2.0', id => 2, method => 'shutdown', params => +{} },
        +{ jsonrpc => '2.0', method => 'exit' },
    );

    # First response: initialize result
    my $init = $results[0];
    is $init->{id}, 1, 'initialize response id';
    ok $init->{result}{capabilities}, 'has capabilities';
    ok $init->{result}{capabilities}{hoverProvider}, 'hover provider';
    ok $init->{result}{capabilities}{completionProvider}, 'completion provider';

    # Second response: shutdown result
    my $shut = $results[1];
    is $shut->{id}, 2, 'shutdown response id';
};

# ── Unknown method returns error ─────────────────

subtest 'unknown method returns error' => sub {
    my @results = run_session(
        +{ jsonrpc => '2.0', id => 1, method => 'initialize', params => +{} },
        +{ jsonrpc => '2.0', id => 2, method => 'unknown/method', params => +{} },
        +{ jsonrpc => '2.0', id => 3, method => 'shutdown' },
        +{ jsonrpc => '2.0', method => 'exit' },
    );

    # Find the error response
    my ($error) = grep { $_->{id} && $_->{id} == 2 } @results;
    ok $error, 'got response for unknown method';
    ok $error->{error}, 'is an error';
    is $error->{error}{code}, -32601, 'method not found code';
};

done_testing;
