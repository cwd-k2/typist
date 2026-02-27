#!/usr/bin/env perl
#
# E2E smoke test for typist-lsp.
# Launches bin/typist-lsp as a subprocess via IPC::Open2 and exercises
# the full LSP lifecycle over stdio pipes.
#
use v5.40;
use IPC::Open2;
use JSON::PP;

my $JSON = JSON::PP->new->utf8->canonical;

# ── Framing helpers ─────────────────────────────

sub frame ($msg) {
    my $body = $JSON->encode($msg);
    "Content-Length: " . length($body) . "\r\n\r\n$body";
}

sub read_response ($fh) {
    my $header = <$fh>;
    return undef unless defined $header && $header =~ /Content-Length:\s*(\d+)/i;
    my $len = $1;

    # Consume blank line after headers
    scalar <$fh>;

    my $body = '';
    my $remaining = $len;
    while ($remaining > 0) {
        my $read = read($fh, my $chunk, $remaining);
        return undef unless $read;
        $body      .= $chunk;
        $remaining -= $read;
    }

    $JSON->decode($body);
}

sub send_msg ($fh, $msg) {
    print $fh frame($msg);
}

# ── Test harness ────────────────────────────────

my $pass = 0;
my $fail = 0;
my $total = 7;

sub ok_test ($ok, $desc) {
    if ($ok) {
        $pass++;
        say "  ok - $desc";
    } else {
        $fail++;
        say "  FAIL - $desc";
    }
}

# ── Launch server ───────────────────────────────

alarm(10);
$SIG{ALRM} = sub { say "TIMEOUT - server did not respond within 10s"; exit 1 };

my $pid = open2(my $from_srv, my $to_srv, 'perl', 'bin/typist-lsp')
    or die "Failed to launch typist-lsp: $!\n";

binmode $from_srv, ':raw';
binmode $to_srv,   ':raw';

# ── 1. Initialize ──────────────────────────────

say "# 1. initialize";
send_msg($to_srv, +{ jsonrpc => '2.0', id => 1, method => 'initialize', params => +{} });
my $init = read_response($from_srv);
ok_test($init && $init->{result}{capabilities}, 'initialize returns capabilities');

send_msg($to_srv, +{ jsonrpc => '2.0', method => 'initialized', params => +{} });

# ── 2. didOpen (clean code) — empty diagnostics ─

say "# 2. didOpen clean code";
send_msg($to_srv, +{
    jsonrpc => '2.0',
    method  => 'textDocument/didOpen',
    params  => +{
        textDocument => +{
            uri     => 'file:///e2e/clean.pm',
            text    => "use v5.40;\nsub inc :Params(Int) :Returns(Int) (\$x) { \$x + 1 }\n",
            version => 1,
        },
    },
});
my $diag_clean = read_response($from_srv);
ok_test(
    $diag_clean
      && ($diag_clean->{method} // '') eq 'textDocument/publishDiagnostics'
      && scalar @{$diag_clean->{params}{diagnostics}} == 0,
    'clean code produces empty diagnostics',
);

# ── 3. didOpen (alias cycle) — error diagnostics ─

say "# 3. didOpen alias cycle";
send_msg($to_srv, +{
    jsonrpc => '2.0',
    method  => 'textDocument/didOpen',
    params  => +{
        textDocument => +{
            uri     => 'file:///e2e/cycle.pm',
            text    => "use v5.40;\ntypedef CycleA => 'CycleB';\ntypedef CycleB => 'CycleA';\n",
            version => 1,
        },
    },
});
my $diag_cycle = read_response($from_srv);
ok_test(
    $diag_cycle
      && ($diag_cycle->{method} // '') eq 'textDocument/publishDiagnostics'
      && scalar @{$diag_cycle->{params}{diagnostics}} > 0,
    'alias cycle produces error diagnostics',
);

# ── 4. Hover ──────────────────────────────────

say "# 4. hover";
send_msg($to_srv, +{
    jsonrpc => '2.0', id => 2,
    method  => 'textDocument/hover',
    params  => +{
        textDocument => +{ uri => 'file:///e2e/clean.pm' },
        position     => +{ line => 1, character => 5 },
    },
});
my $hover = read_response($from_srv);
ok_test(
    $hover && $hover->{id} == 2 && $hover->{result}
      && $hover->{result}{contents}{value} =~ /sub inc/,
    'hover returns function signature',
);

# ── 5. Completion ────────────────────────────────

say "# 5. completion";
send_msg($to_srv, +{
    jsonrpc => '2.0',
    method  => 'textDocument/didOpen',
    params  => +{
        textDocument => +{
            uri     => 'file:///e2e/comp.pm',
            text    => "use v5.40;\nsub foo :Params(",
            version => 1,
        },
    },
});
read_response($from_srv);  # consume diagnostics

send_msg($to_srv, +{
    jsonrpc => '2.0', id => 3,
    method  => 'textDocument/completion',
    params  => +{
        textDocument => +{ uri => 'file:///e2e/comp.pm' },
        position     => +{ line => 1, character => length('sub foo :Params(') },
    },
});
my $comp = read_response($from_srv);
my @labels = map { $_->{label} } @{($comp->{result}{items} // [])};
ok_test(
    $comp && $comp->{id} == 3 && (grep { $_ eq 'Int' } @labels),
    'completion returns type names',
);

# ── 6. Unknown method — -32601 error ────────────

say "# 6. unknown method";
send_msg($to_srv, +{ jsonrpc => '2.0', id => 4, method => 'bogus/method', params => +{} });
my $err = read_response($from_srv);
ok_test(
    $err && $err->{id} == 4 && $err->{error} && $err->{error}{code} == -32601,
    'unknown method returns -32601',
);

# ── 7. Shutdown + Exit ──────────────────────────

say "# 7. shutdown + exit";
send_msg($to_srv, +{ jsonrpc => '2.0', id => 5, method => 'shutdown' });
my $shut = read_response($from_srv);
send_msg($to_srv, +{ jsonrpc => '2.0', method => 'exit' });

close $to_srv;
waitpid($pid, 0);
my $exit_code = $? >> 8;
ok_test(
    $shut && $shut->{id} == 5 && $exit_code == 0,
    'shutdown + exit with code 0',
);

alarm(0);

# ── Summary ─────────────────────────────────────

say '';
say "$pass/$total passed" . ($fail ? " ($fail failed)" : '');
exit($fail ? 1 : 0);
