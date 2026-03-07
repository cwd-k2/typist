package Test::Typist::Analyze;
use v5.40;

use Exporter 'import';

use Typist::Static::Analyzer;

our @EXPORT_OK = qw(
    analyze
    diags_of_kind
    type_errors
    arity_errors
);

sub analyze ($source, %opts) {
    return Typist::Static::Analyzer->analyze($source, %opts);
}

sub diags_of_kind ($source, $kind, %opts) {
    my $result = analyze($source, %opts);
    return [grep { ($_->{kind} // '') eq $kind } $result->{diagnostics}->@*];
}

sub type_errors ($source, %opts) {
    return diags_of_kind($source, 'TypeMismatch', %opts);
}

sub arity_errors ($source, %opts) {
    return diags_of_kind($source, 'ArityMismatch', %opts);
}

1;
