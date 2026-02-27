package Typist::Error;
use v5.40;

# ── Error Object ─────────────────────────────────

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

# ── Global Batch Collector (backward compat) ────

my @ERRORS;

sub collect ($invocant, %args) {
    my $err = Typist::Error->new(%args);
    if (ref $invocant && $invocant->isa('Typist::Error::Collector')) {
        push $invocant->{errors}->@*, $err;
    } else {
        push @ERRORS, $err;
    }
}

sub has_errors ($invocant) {
    if (ref $invocant && $invocant->isa('Typist::Error::Collector')) {
        return scalar $invocant->{errors}->@*;
    }
    scalar @ERRORS;
}

sub errors ($invocant) {
    if (ref $invocant && $invocant->isa('Typist::Error::Collector')) {
        return $invocant->{errors}->@*;
    }
    @ERRORS;
}

sub report ($invocant) {
    my @errs = ref $invocant && $invocant->isa('Typist::Error::Collector')
        ? $invocant->{errors}->@*
        : @ERRORS;

    return unless @errs;
    my $n = scalar @errs;
    my $s = $n == 1 ? '' : 's';

    my $report = "Typist found $n type error${s}:\n\n";
    $report .= $_->to_string . "\n" for @errs;
    $report;
}

sub reset ($invocant) {
    if (ref $invocant && $invocant->isa('Typist::Error::Collector')) {
        $invocant->{errors} = [];
    } else {
        @ERRORS = ();
    }
}

# ── Collector Factory ────────────────────────────

sub collector ($class) {
    bless { errors => [] }, 'Typist::Error::Collector';
}

# ── Collector Class ──────────────────────────────

package Typist::Error::Collector;
use v5.40;
our @ISA = ('Typist::Error');

1;
