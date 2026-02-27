package Typist::LSP::Logger;
use v5.40;

# Log levels: 0=off, 1=error, 2=warn, 3=info, 4=debug, 5=trace
my %LEVEL_NUM = (off => 0, error => 1, warn => 2, info => 3, debug => 4, trace => 5);
my %NUM_LABEL = reverse %LEVEL_NUM;

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    my $level = $args{level} // $ENV{TYPIST_LSP_LOG} // 'info';
    $level = $LEVEL_NUM{$level} // $level;  # accept both name and number

    my $fh = $args{fh} // \*STDERR;
    binmode $fh, ':utf8';

    bless +{ level => $level, fh => $fh }, $class;
}

# ── Level Check ──────────────────────────────────

sub level ($self, @rest) {
    if (@rest) {
        my $new = shift @rest;
        $self->{level} = $LEVEL_NUM{$new} // $new;
    }
    $self->{level};
}

# ── Logging Methods ──────────────────────────────

sub error ($self, @msg) { $self->_log(1, @msg) }
sub warn  ($self, @msg) { $self->_log(2, @msg) }
sub info  ($self, @msg) { $self->_log(3, @msg) }
sub debug ($self, @msg) { $self->_log(4, @msg) }
sub trace ($self, @msg) { $self->_log(5, @msg) }

# ── Internal ─────────────────────────────────────

sub _log ($self, $lvl, @msg) {
    return if $lvl > $self->{level};

    my $label = $NUM_LABEL{$lvl} // '???';
    my $ts    = _timestamp();
    my $text  = join(' ', @msg);

    my $fh = $self->{fh};
    print $fh "[$ts] [$label] $text\n";
}

sub _timestamp () {
    my @t = localtime;
    sprintf '%02d:%02d:%02d', @t[2, 1, 0];
}

1;
