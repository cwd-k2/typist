package Typist::Error;
use v5.40;

our $VERSION = '0.01';

# ── Error Value Object ───────────────────────────

sub new ($class, %args) {
    bless +{
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

# ── Collector ────────────────────────────────────
# Instance-based error accumulator for isolated analysis (LSP, static checker).

sub collector ($class) {
    Typist::Error::Collector->new;
}

# ── Reporting Helpers ────────────────────────────

sub _format_report (@errs) {
    return unless @errs;
    my $n = scalar @errs;
    my $s = $n == 1 ? '' : 's';

    my $report = "Typist found $n type error${s}:\n\n";
    $report .= $_->to_string . "\n" for @errs;
    $report;
}

# ── Collector Class ──────────────────────────────

package Typist::Error::Collector;
use v5.40;

sub new ($class) {
    bless +{ errors => [] }, $class;
}

sub collect ($self, %args) {
    push $self->{errors}->@*, Typist::Error->new(%args);
}

sub has_errors ($self) {
    scalar $self->{errors}->@*;
}

sub errors ($self) {
    $self->{errors}->@*;
}

sub report ($self) {
    Typist::Error::_format_report($self->{errors}->@*);
}

sub reset ($self) {
    $self->{errors} = [];
}

1;
