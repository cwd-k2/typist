use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;

sub type_errors ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq 'TypeMismatch' } $result->{diagnostics}->@* ];
}

sub all_errors ($source) {
    my $result = Typist::Static::Analyzer->analyze($source);
    $result->{diagnostics};
}

# ── ref($x) eq 'HASH' → HashRef[Any] ────────

subtest 'ref narrowing: HASH → HashRef[Any]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) eq 'HASH') {
        my $h :sig(HashRef[Any]) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ref HASH narrowing allows HashRef assignment';
};

# ── ref($x) eq 'ARRAY' → ArrayRef[Any] ──────

subtest 'ref narrowing: ARRAY → ArrayRef[Any]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) eq 'ARRAY') {
        my $a :sig(ArrayRef[Any]) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ref ARRAY narrowing allows ArrayRef assignment';
};

# ── ref($x) eq 'SCALAR' → Ref[Any] ──────────

subtest 'ref narrowing: SCALAR → Ref[Any]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) eq 'SCALAR') {
        my $r :sig(Ref[Any]) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ref SCALAR narrowing allows Ref assignment';
};

# ── Unknown ref string → no narrowing ────────

subtest 'ref narrowing: unknown type string skipped' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) eq 'UNKNOWN') {
        my $y = $x;
    }
}
PERL

    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @$errs;
    is scalar @type_errs, 0, 'unknown ref type does not cause errors';
};

# ── else-block: no inverse narrowing ─────────

subtest 'ref narrowing: else block has no inverse' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) eq 'HASH') {
        my $h :sig(HashRef[Any]) = $x;
    } else {
        my $y :sig(Str) = $x;
    }
}
PERL

    # The else block should NOT narrow — $x remains Any, so Str assignment is OK (Any → skip)
    is scalar @$errs, 0, 'else block does not narrow (gradual skip on Any)';
};

# ── ne operator: no narrowing ────────────────

subtest 'ref narrowing: ne operator skipped' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) ne 'HASH') {
        my $y = $x;
    }
}
PERL

    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @$errs;
    is scalar @type_errs, 0, 'ne operator does not trigger narrowing';
};

done_testing;
