package Typist::Error;
use v5.40;

# ── Error Object ──────────────────────────────────

sub new ($class, %args) {
    bless {
        kind    => $args{kind}    // 'TypeError',
        message => $args{message} // 'unknown error',
        file    => $args{file}    // '(unknown)',
        line    => $args{line}    // 0,
    }, $class;
}

sub kind    ($self) { $self->{kind} }
sub message ($self) { $self->{message} }
sub file    ($self) { $self->{file} }
sub line    ($self) { $self->{line} }

sub to_string ($self) {
    sprintf "  - [%s] %s\n      at %s line %d",
        $self->{kind}, $self->{message}, $self->{file}, $self->{line};
}

# ── Batch Collector ───────────────────────────────

my @ERRORS;

sub collect ($class, %args) {
    push @ERRORS, $class->new(%args);
}

sub has_errors ($class) {
    scalar @ERRORS;
}

sub errors ($class) {
    @ERRORS;
}

sub report ($class) {
    return unless @ERRORS;
    my $n = scalar @ERRORS;
    my $s = $n == 1 ? '' : 's';

    my $report = "Typist found $n type error${s}:\n\n";
    $report .= $_->to_string . "\n" for @ERRORS;
    $report;
}

sub reset ($class) {
    @ERRORS = ();
}

1;
