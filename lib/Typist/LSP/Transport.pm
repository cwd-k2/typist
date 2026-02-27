package Typist::LSP::Transport;
use v5.40;

use JSON::PP;

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

    bless { in => $in, out => $out }, $class;
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

    # Read exactly content_length bytes
    my $body;
    my $read = read($in, $body, $content_length);
    return undef unless $read && $read == $content_length;

    $JSON->decode($body);
}

# ── Writing ──────────────────────────────────────

sub _send ($self, $msg) {
    my $body = $JSON->encode($msg);
    my $len  = length($body);
    my $out  = $self->{out};

    print $out "Content-Length: $len\r\n\r\n$body";
}

sub send_response ($self, $id, $result) {
    $self->_send({
        jsonrpc => '2.0',
        id      => $id,
        result  => $result,
    });
}

sub send_error ($self, $id, $code, $message) {
    $self->_send({
        jsonrpc => '2.0',
        id      => $id,
        error   => { code => $code, message => $message },
    });
}

sub send_notification ($self, $method, $params) {
    $self->_send({
        jsonrpc => '2.0',
        method  => $method,
        params  => $params,
    });
}

1;
