package Typist::LSP::Transport;
use v5.40;

our $VERSION = '0.01';

use JSON::PP;
use Time::HiRes ();

my $JSON = JSON::PP->new->utf8->canonical;
my $MAX_CONTENT_LENGTH = 10 * 1024 * 1024;  # 10MB

# ── URI Utilities ───────────────────────────────

sub uri_to_path ($uri) {
    $uri =~ s{^file://}{};
    $uri =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $uri;
}

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
    return undef if $content_length > $MAX_CONTENT_LENGTH;

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

__END__

=head1 NAME

Typist::LSP::Transport - JSON-RPC transport layer with Content-Length framing

=head1 DESCRIPTION

Handles reading and writing LSP JSON-RPC messages over stdio.  Implements
the Content-Length header framing protocol with partial-read support for
pipes, and provides optional JSONL tracing via the C<TYPIST_LSP_TRACE>
environment variable.

=head2 uri_to_path

    my $path = Typist::LSP::Transport::uri_to_path($uri);

Strips the C<file://> prefix and percent-decodes a URI, returning a
filesystem path.  Shared utility used by L<Typist::LSP::Server> and
L<Typist::LSP::Document>.

=head2 new

    my $transport = Typist::LSP::Transport->new(
        in  => \*STDIN,
        out => \*STDOUT,
    );

Creates a new transport.  C<in> and C<out> default to C<STDIN>/C<STDOUT>.
Both handles are set to C<:raw> mode and output is unbuffered.  If
C<TYPIST_LSP_TRACE> is set to a file path, all messages are recorded
there in JSONL format.

=head2 read_message

    my $msg = $transport->read_message;

Reads one JSON-RPC message from the input handle.  Parses
Content-Length headers, performs a partial-read loop to collect the
full body, and returns the decoded hashref.  Returns C<undef> on EOF.

=head2 send_response

    $transport->send_response($id, $result);

Sends a JSON-RPC success response with the given C<$id> and C<$result>
payload.

=head2 send_error

    $transport->send_error($id, $code, $message);

Sends a JSON-RPC error response with the given C<$id>, numeric
C<$code>, and human-readable C<$message>.

=head2 send_notification

    $transport->send_notification($method, $params);

Sends a JSON-RPC notification (no C<id> field) with the given
C<$method> name and C<$params> hashref.

=cut
