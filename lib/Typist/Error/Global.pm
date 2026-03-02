package Typist::Error::Global;
use v5.40;

our $VERSION = '0.01';

use Typist::Error;

# Global singleton error buffer for CHECK-phase validation.

my @ERRORS;

sub collect ($class, %args) {
    push @ERRORS, Typist::Error->new(%args);
}

sub has_errors ($class) {
    scalar @ERRORS;
}

sub errors ($class) {
    @ERRORS;
}

sub report ($class) {
    Typist::Error::_format_report(@ERRORS);
}

sub reset ($class) {
    @ERRORS = ();
}

1;

=head1 NAME

Typist::Error::Global - Global singleton error buffer

=head1 SYNOPSIS

    use Typist::Error::Global;

    Typist::Error::Global->collect(
        kind => 'TypeMismatch', message => '...', file => '...', line => 1,
    );

    if (Typist::Error::Global->has_errors) {
        warn Typist::Error::Global->report;
        Typist::Error::Global->reset;
    }

=head1 DESCRIPTION

Global singleton error buffer for CHECK-phase validation. Unlike the
instance-based L<Typist::Error::Collector|Typist::Error/"Typist::Error::Collector">,
this module provides class methods backed by a package-level array.

=head1 METHODS

=head2 collect

    Typist::Error::Global->collect(%args);

Creates and stores a new L<Typist::Error>.

=head2 has_errors

    my $bool = Typist::Error::Global->has_errors;

=head2 errors

    my @errs = Typist::Error::Global->errors;

=head2 report

    my $str = Typist::Error::Global->report;

=head2 reset

    Typist::Error::Global->reset;

Clears the global buffer.

=head1 SEE ALSO

L<Typist::Error>

=cut
