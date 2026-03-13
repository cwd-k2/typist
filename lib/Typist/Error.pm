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
        explanation   => $args{explanation},
        fn_name       => $args{fn_name},
        effect_label  => $args{effect_label},
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
sub explanation   ($self) { $self->{explanation} }
sub fn_name       ($self) { $self->{fn_name} }
sub effect_label  ($self) { $self->{effect_label} }

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

=head1 NAME

Typist::Error - Type error value object and collector

=head1 SYNOPSIS

    use Typist::Error;

    my $err = Typist::Error->new(
        kind    => 'TypeMismatch',
        message => 'expected Int, got Str',
        file    => 'lib/Foo.pm',
        line    => 42,
    );
    say $err->to_string;

    # Instance-based collector for isolated analysis
    my $collector = Typist::Error->collector;
    $collector->collect(kind => 'ArityMismatch', message => '...', file => '...', line => 1);
    warn $collector->report if $collector->has_errors;

=head1 DESCRIPTION

C<Typist::Error> is an immutable value object representing a single type
error with location information. C<Typist::Error::Collector> is an
instance-based error accumulator for isolated analysis contexts (LSP,
static checker).

For the global singleton buffer used during CHECK-phase validation,
see L<Typist::Error::Global>.

=head1 METHODS (Typist::Error)

=head2 new

    my $err = Typist::Error->new(%args);

Creates a new error. Keys: C<kind>, C<message>, C<file>, C<line>,
C<col>, C<end_line>, C<end_col>, C<expected_type>, C<actual_type>,
C<related>, C<suggestions>.

=head2 kind, message, file, line, col

Accessors for error attributes.

=head2 to_string

    my $str = $err->to_string;

Formats the error as a single diagnostic string.

=head1 METHODS (Typist::Error::Collector)

=head2 collect

    $collector->collect(%args);

Creates and stores a new error.

=head2 has_errors

    my $bool = $collector->has_errors;

Returns true if any errors have been collected.

=head2 errors

    my @errs = $collector->errors;

Returns all collected error objects.

=head2 report

    my $str = $collector->report;

Formats all collected errors as a human-readable report.

=head2 reset

    $collector->reset;

Clears all collected errors.

=head1 SEE ALSO

L<Typist::Error::Global>, L<Typist::Static::Checker>

=cut
