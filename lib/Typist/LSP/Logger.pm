package Typist::LSP::Logger;
use v5.40;

our $VERSION = '0.01';

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

__END__

=head1 NAME

Typist::LSP::Logger - Leveled stderr logger for the Typist LSP server

=head1 DESCRIPTION

Provides timestamped, level-filtered logging to stderr (or a custom
handle).  The log level can be set via the C<TYPIST_LSP_LOG> environment
variable or the C<level> constructor argument.  Levels are: C<off>,
C<error>, C<warn>, C<info>, C<debug>, C<trace>.

=head2 new

    my $log = Typist::LSP::Logger->new(
        level => 'debug',   # or 0..5, default: $ENV{TYPIST_LSP_LOG} // 'info'
        fh    => \*STDERR,  # default
    );

Creates a new logger.  Accepts a level name or numeric value and an
optional output filehandle.

=head2 level

    my $current = $log->level;
    $log->level('debug');

Gets or sets the current log level.  Accepts both level names and
numeric values.

=head2 error

    $log->error('something failed:', $detail);

Logs a message at the C<error> level (1).

=head2 warn

    $log->warn('potential issue');

Logs a message at the C<warn> level (2).

=head2 info

    $log->info('server started');

Logs a message at the C<info> level (3).

=head2 debug

    $log->debug('processing file', $path);

Logs a message at the C<debug> level (4).

=head2 trace

    $log->trace('raw message', $data);

Logs a message at the C<trace> level (5).

=cut
