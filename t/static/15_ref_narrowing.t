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

# ── ne operator: inverted narrowing ──────────

subtest 'ref narrowing: ne then-block not narrowed' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) ne 'HASH') {
        my $y = $x;
    }
}
PERL

    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @$errs;
    is scalar @type_errs, 0, 'ne then-block: no narrowing (Any → skip)';
};

subtest 'ref narrowing: ne else-block narrowed to type' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) ne 'HASH') {
        my $y = $x;
    } else {
        my $h :sig(HashRef[Any]) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ne else-block: $x narrowed to HashRef[Any]';
};

# ── Variable comparison: ref($x) eq $type_var ──

subtest 'ref narrowing: variable comparison with Literal' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any, Literal["ARRAY"]) -> Void) ($x, $type) {
    if (ref($x) eq $type) {
        my $a :sig(ArrayRef[Any]) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'variable comparison narrows when var is Literal string';
};

subtest 'ref narrowing: unknown variable comparison skipped' => sub {
    my $errs = all_errors(<<'PERL');
use v5.40;
sub check :sig((Any, Str) -> Void) ($x, $type) {
    if (ref($x) eq $type) {
        my $y = $x;
    }
}
PERL

    my @type_errs = grep { $_->{kind} eq 'TypeMismatch' } @$errs;
    is scalar @type_errs, 0, 'unknown variable comparison does not trigger narrowing';
};

# ── ref $x eq 'HASH' (no parens) → HashRef[Any] ──

subtest 'ref narrowing: no parens — ref $x eq HASH' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref $x eq 'HASH') {
        my $h :sig(HashRef[Any]) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ref without parens narrows to HashRef[Any]';
};

subtest 'ref narrowing: no parens — ref $x eq ARRAY' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref $x eq 'ARRAY') {
        my $a :sig(ArrayRef[Any]) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ref without parens narrows to ArrayRef[Any]';
};

# ── ref($x) eq 'REF' → Ref[Any] ──────────────

subtest 'ref narrowing: REF → Ref[Any]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) eq 'REF') {
        my $r :sig(Ref[Any]) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ref REF narrowing allows Ref assignment';
};

# ── ref($x) eq 'Regexp' → Ref[Any] ───────────

subtest 'ref narrowing: Regexp → Ref[Any]' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) eq 'Regexp') {
        my $r :sig(Ref[Any]) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ref Regexp narrowing allows Ref assignment';
};

# ── ref($x) eq 'VSTRING' → Str ───────────────

subtest 'ref narrowing: VSTRING → Str' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) eq 'VSTRING') {
        my $s :sig(Str) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ref VSTRING narrowing allows Str assignment';
};

# ── Inverse narrowing: ref with Union ─────────

subtest 'ref inverse narrowing: Union type in else-block' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((HashRef[Any] | ArrayRef[Any]) -> Void) ($x) {
    if (ref($x) eq 'HASH') {
        my $h :sig(HashRef[Any]) = $x;
    } else {
        my $a :sig(ArrayRef[Any]) = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ref else-block narrows Union to remaining member';
};

subtest 'ref inverse narrowing: non-Union no inverse' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
sub check :sig((Any) -> Void) ($x) {
    if (ref($x) eq 'HASH') {
        my $h :sig(HashRef[Any]) = $x;
    } else {
        my $y = $x;
    }
}
PERL

    is scalar @$errs, 0, 'ref else-block on non-Union: no error (gradual)';
};

# ── Inverse narrowing: isa with Union ─────────

subtest 'isa inverse narrowing: Union type in else-block' => sub {
    my $errs = type_errors(<<'PERL');
use v5.40;
struct Cat => (name => 'Str');
struct Dog => (name => 'Str');

sub check :sig((Cat | Dog) -> Str) ($pet) {
    if ($pet isa Cat) {
        return $pet->name();
    } else {
        my $d :sig(Dog) = $pet;
        return $d->name();
    }
}
PERL

    is scalar @$errs, 0, 'isa else-block narrows Union to remaining struct';
};

done_testing;
