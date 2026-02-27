package Typist::Error::Global;
use v5.40;

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
