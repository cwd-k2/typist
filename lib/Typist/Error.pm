package Typist::Error;
use v5.40;

our $VERSION = '0.01';

# ── Error Value Object ───────────────────────────

sub new ($class, %args) {
    bless +{
        kind          => $args{kind}          // 'TypeError',
        message       => $args{message}       // 'unknown error',
        file          => $args{file}          // '(unknown)',
        line          => $args{line}          // 0,
        col           => $args{col}           // 0,
        end_line      => $args{end_line},
        end_col       => $args{end_col},
        expected_type => $args{expected_type},
        actual_type   => $args{actual_type},
        related       => $args{related},
        suggestions   => $args{suggestions},
    }, $class;
}

sub kind          ($self) { $self->{kind} }
sub message       ($self) { $self->{message} }
sub file          ($self) { $self->{file} }
sub line          ($self) { $self->{line} }
sub col           ($self) { $self->{col} }
sub end_line      ($self) { $self->{end_line} }
sub end_col       ($self) { $self->{end_col} }
sub expected_type ($self) { $self->{expected_type} }
sub actual_type   ($self) { $self->{actual_type} }
sub related       ($self) { $self->{related} }
sub suggestions   ($self) { $self->{suggestions} }

sub to_string ($self) {
    my $loc = $self->{col} > 0
        ? sprintf("at %s line %d col %d", $self->{file}, $self->{line}, $self->{col})
        : sprintf("at %s line %d",        $self->{file}, $self->{line});
    sprintf "  - [%s] %s\n      %s", $self->{kind}, $self->{message}, $loc;
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
