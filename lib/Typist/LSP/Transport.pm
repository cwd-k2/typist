package Typist::LSP::Transport;
use v5.40;

use JSON::PP;
use Time::HiRes ();

my $JSON = JSON::PP->new->utf8->canonical;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    my $in  = $args{in}  // \*STDIN;
    my $out = $args{out} // \*STDOUT;

    # Ensure output is unbuffered
    my $old = select $out;
    $| = 1;
    select $old;

    binmode $in,  ':raw';
    binmode $out, ':raw';

    # JSONL trace: TYPIST_LSP_TRACE=path enables message recording
    my $trace_fh;
    if (my $path = $ENV{TYPIST_LSP_TRACE}) {
        open $trace_fh, '>>', $path or warn "trace open failed: $!\n";
        if ($trace_fh) {
            my $prev = select $trace_fh; $| = 1; select $prev;
        }
    }

    bless +{ in => $in, out => $out, trace_fh => $trace_fh }, $class;
}

# ── Reading ──────────────────────────────────────

sub read_message ($self) {
    my $in = $self->{in};

    # Read headers until blank line
    my $content_length;
    while (my $header = <$in>) {
        $header =~ s/\r?\n\z//;
        last if $header eq '';

        if ($header =~ /\AContent-Length:\s*(\d+)\z/i) {
            $content_length = $1;
        }
    }

    return undef unless defined $content_length;

    # Read exactly content_length bytes (may require multiple reads on pipes)
    my $body = '';
    my $remaining = $content_length;
    while ($remaining > 0) {
        my $read = read($in, my $chunk, $remaining);
        return undef unless $read;  # EOF or error
        $body      .= $chunk;
        $remaining -= $read;
    }

    my $msg = $JSON->decode($body);
    $self->_trace('recv', $msg);
    $msg;
}

# ── Writing ──────────────────────────────────────

sub _send ($self, $msg) {
    $self->_trace('send', $msg);
    my $body = $JSON->encode($msg);
    my $len  = length($body);
    my $out  = $self->{out};

    print $out "Content-Length: $len\r\n\r\n$body";
}

# ── Tracing ─────────────────────────────────────

sub _trace ($self, $dir, $msg) {
    my $fh = $self->{trace_fh} // return;
    my ($s, $us) = Time::HiRes::gettimeofday();
    my @t = localtime($s);
    my $ts = sprintf('%02d:%02d:%02d.%03d', $t[2], $t[1], $t[0], int($us / 1000));
    print $fh $JSON->encode(+{ dir => $dir, ts => $ts, msg => $msg }), "\n";
}

sub send_response ($self, $id, $result) {
    $self->_send(+{
        jsonrpc => '2.0',
        id      => $id,
        result  => $result,
    });
}

sub send_error ($self, $id, $code, $message) {
    $self->_send(+{
        jsonrpc => '2.0',
        id      => $id,
        error   => +{ code => $code, message => $message },
    });
}

sub send_notification ($self, $method, $params) {
    $self->_send(+{
        jsonrpc => '2.0',
        method  => $method,
        params  => $params,
    });
}

1;
