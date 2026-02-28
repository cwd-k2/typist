use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;
use Typist::Registry;

# Helper: analyze source, return diagnostics of a given kind
sub diags_of ($source, $kind, %opts) {
    my $result = Typist::Static::Analyzer->analyze($source, %opts);
    [ grep { $_->{kind} eq $kind } $result->{diagnostics}->@* ];
}

# ── Prelude installs standard effects ────────────

subtest 'prelude: IO and Exn effects are known' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package PreludeEffects;
use v5.40;

sub io_fn :Type(() -> Void !Eff(IO)) () { }
sub exn_fn :Type(() -> Void !Eff(Exn)) () { }
PERL

    my @unknown = grep { $_->{kind} eq 'UnknownEffect' } $result->{diagnostics}->@*;
    my @io_unknown  = grep { $_->{message} =~ /\bIO\b/ } @unknown;
    my @exn_unknown = grep { $_->{message} =~ /\bExn\b/ } @unknown;
    is scalar @io_unknown, 0, 'IO is a known effect (from prelude)';
    is scalar @exn_unknown, 0, 'Exn is a known effect (from prelude)';
};

# ── Type checking: builtin argument types ────────

subtest 'typecheck: length(Int) → TypeMismatch' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package LengthCheck;
use v5.40;

sub count :Type((Int) -> Int) ($n) {
    return length($n);
}
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/length.*Str.*Int/, 'length expects Str, got Int';
};

subtest 'typecheck: length(Str) → no error' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package LengthOk;
use v5.40;

sub count :Type((Str) -> Int) ($s) {
    return length($s);
}
PERL

    is scalar @$errs, 0, 'no type error: length(Str) is fine';
};

subtest 'typecheck: uc(Int) → TypeMismatch' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package UcCheck;
use v5.40;

sub upper :Type((Int) -> Str) ($n) {
    return uc($n);
}
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/uc.*Str.*Int/, 'uc expects Str, got Int';
};

subtest 'typecheck: abs(Str) → TypeMismatch' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package AbsCheck;
use v5.40;

sub positive :Type((Str) -> Num) ($s) {
    return abs($s);
}
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/abs.*Num.*Str/, 'abs expects Num, got Str';
};

# ── Return type inference from builtins ──────────

subtest 'infer: length() returns Int' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package InferLength;
use v5.40;

my $x :Type(Str) = length("hello");
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/\$x.*Str.*Int/, 'length returns Int, not Str';
};

subtest 'infer: length() return assigned to Int → no error' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package InferLengthOk;
use v5.40;

my $x :Type(Int) = length("hello");
PERL

    is scalar @$errs, 0, 'length returns Int, assigned to Int — no error';
};

subtest 'infer: uc() returns Str' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package InferUc;
use v5.40;

my $x :Type(Int) = uc("hello");
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/\$x.*Int.*Str/, 'uc returns Str, not Int';
};

# ── Effect checking: builtin IO effects ──────────

subtest 'effects: say in Eff(IO) function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package SayInIO;
use v5.40;

sub greet :Type((Str) -> Void !Eff(IO)) ($name) {
    say "Hello, $name";
}
PERL

    is scalar @$errs, 0, 'say in Eff(IO) function — no effect error';
};

subtest 'effects: say in pure function → EffectMismatch' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package SayInPure;
use v5.40;

sub greet :Type((Str) -> Str) ($name) {
    say "Hello, $name";
    return $name;
}
PERL

    ok scalar @$errs > 0, 'say in pure function flagged';
    like $errs->[0]{message}, qr/IO/, 'reports IO effect requirement';
};

subtest 'effects: die in Eff(Exn) function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package DieInExn;
use v5.40;

sub fail :Type((Str) -> Never !Eff(Exn)) ($msg) {
    die($msg);
}
PERL

    is scalar @$errs, 0, 'die in Eff(Exn) function — no effect error';
};

subtest 'effects: die in Eff(IO) function → EffectMismatch' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package DieInIO;
use v5.40;

sub io_only :Type((Str) -> Void !Eff(IO)) ($msg) {
    die($msg);
}
PERL

    ok scalar @$errs > 0, 'die in Eff(IO) function flagged (needs Exn)';
    like $errs->[0]{message}, qr/Exn/, 'reports Exn effect requirement';
};

subtest 'effects: pure builtin (length) in pure function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package PureBuiltin;
use v5.40;

sub count :Type((Str) -> Int) ($s) {
    length($s);
}
PERL

    is scalar @$errs, 0, 'pure builtin in pure function — no effect error';
};

# ── User declare overrides prelude ───────────────

subtest 'override: user declare overrides prelude say' => sub {
    my $ws_reg = Typist::Registry->new;
    require Typist::Effect;
    $ws_reg->register_effect('Console', Typist::Effect->new(
        name => 'Console', operations => +{},
    ));

    my $errs = diags_of(<<'PERL', 'EffectMismatch', workspace_registry => $ws_reg);
package OverrideSay;
use v5.40;

declare say => '(Str) -> Void !Eff(Console)';

sub greet :Type((Str) -> Void !Eff(Console)) ($name) {
    say "Hello, $name";
}
PERL

    is scalar @$errs, 0, 'user declare overrides prelude: say is Eff(Console), no mismatch';
};

subtest 'override: user declare pure length works' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package OverrideLength;
use v5.40;

declare length => '(Str) -> Int';

sub count :Type((Str) -> Int) ($s) {
    length($s);
}
PERL

    is scalar @$errs, 0, 'user declare pure length — no effect error';
};

# ── Multiple builtins in one function ────────────

subtest 'effects: multiple builtins with same effect → OK' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package MultiBuiltin;
use v5.40;

sub verbose :Type((Str) -> Void !Eff(IO)) ($msg) {
    print "LOG: ";
    say $msg;
}
PERL

    is scalar @$errs, 0, 'multiple IO builtins in Eff(IO) function — no error';
};

subtest 'effects: mixed IO and Exn builtins → need both' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package MixedEffects;
use v5.40;

sub bail :Type((Str) -> Never !Eff(IO | Exn)) ($msg) {
    say $msg;
    die($msg);
}
PERL

    is scalar @$errs, 0, 'IO + Exn builtins in Eff(IO | Exn) function — no error';
};

subtest 'effects: mixed builtins missing one effect → flagged' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package MissingEffect;
use v5.40;

sub bail :Type((Str) -> Never !Eff(IO)) ($msg) {
    say $msg;
    die($msg);
}
PERL

    ok scalar @$errs > 0, 'die requires Exn, caller only has IO';
    like $errs->[0]{message}, qr/Exn/, 'reports missing Exn effect';
};

done_testing;
