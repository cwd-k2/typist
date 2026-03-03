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

subtest 'prelude: IO, Exn, and Decl effects are known' => sub {
    my $result = Typist::Static::Analyzer->analyze(<<'PERL');
package PreludeEffects;
use v5.40;

sub io_fn :sig(() -> Void ![IO]) () { }
sub exn_fn :sig(() -> Void ![Exn]) () { }
sub decl_fn :sig(() -> Void ![Decl]) () { }
PERL

    my @unknown = grep { $_->{kind} eq 'UnknownEffect' } $result->{diagnostics}->@*;
    my @io_unknown   = grep { $_->{message} =~ /\bIO\b/ } @unknown;
    my @exn_unknown  = grep { $_->{message} =~ /\bExn\b/ } @unknown;
    my @decl_unknown = grep { $_->{message} =~ /\bDecl\b/ } @unknown;
    is scalar @io_unknown, 0, 'IO is a known effect (from prelude)';
    is scalar @exn_unknown, 0, 'Exn is a known effect (from prelude)';
    is scalar @decl_unknown, 0, 'Decl is a known effect (from prelude)';
};

# ── Type checking: builtin argument types ────────

subtest 'typecheck: length(Int) → TypeMismatch' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package LengthCheck;
use v5.40;

sub count :sig((Int) -> Int) ($n) {
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

sub count :sig((Str) -> Int) ($s) {
    return length($s);
}
PERL

    is scalar @$errs, 0, 'no type error: length(Str) is fine';
};

subtest 'typecheck: uc(Int) → TypeMismatch' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package UcCheck;
use v5.40;

sub upper :sig((Int) -> Str) ($n) {
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

sub positive :sig((Str) -> Num) ($s) {
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

my $x :sig(Str) = length("hello");
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/\$x.*Str.*Int/, 'length returns Int, not Str';
};

subtest 'infer: length() return assigned to Int → no error' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package InferLengthOk;
use v5.40;

my $x :sig(Int) = length("hello");
PERL

    is scalar @$errs, 0, 'length returns Int, assigned to Int — no error';
};

subtest 'infer: uc() returns Str' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
package InferUc;
use v5.40;

my $x :sig(Int) = uc("hello");
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/\$x.*Int.*Str/, 'uc returns Str, not Int';
};

# ── Effect checking: builtin IO effects ──────────

subtest 'effects: say in ![IO] function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package SayInIO;
use v5.40;

sub greet :sig((Str) -> Void ![IO]) ($name) {
    say "Hello, $name";
}
PERL

    is scalar @$errs, 0, 'say in ![IO] function — no effect error';
};

subtest 'effects: say in pure function — IO is ambient' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package SayInPure;
use v5.40;

sub greet :sig((Str) -> Str) ($name) {
    say "Hello, $name";
    return $name;
}
PERL

    is scalar @$errs, 0, 'IO is ambient — no EffectMismatch for say in pure function';
};

subtest 'effects: die in ![Exn] function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package DieInExn;
use v5.40;

sub fail :sig((Str) -> Never ![Exn]) ($msg) {
    die($msg);
}
PERL

    is scalar @$errs, 0, 'die in ![Exn] function — no effect error';
};

subtest 'effects: die in ![IO] function — Exn is ambient' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package DieInIO;
use v5.40;

sub io_only :sig((Str) -> Void ![IO]) ($msg) {
    die($msg);
}
PERL

    is scalar @$errs, 0, 'Exn is ambient — no EffectMismatch for die in ![IO] function';
};

subtest 'effects: pure builtin (length) in pure function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package PureBuiltin;
use v5.40;

sub count :sig((Str) -> Int) ($s) {
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

declare say => '(Str) -> Void ![Console]';

sub greet :sig((Str) -> Void ![Console]) ($name) {
    say "Hello, $name";
}
PERL

    is scalar @$errs, 0, 'user declare overrides prelude: say is ![Console], no mismatch';
};

subtest 'override: user declare pure length works' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package OverrideLength;
use v5.40;

declare length => '(Str) -> Int';

sub count :sig((Str) -> Int) ($s) {
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

sub verbose :sig((Str) -> Void ![IO]) ($msg) {
    print "LOG: ";
    say $msg;
}
PERL

    is scalar @$errs, 0, 'multiple IO builtins in ![IO] function — no error';
};

subtest 'effects: mixed IO and Exn builtins → need both' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package MixedEffects;
use v5.40;

sub bail :sig((Str) -> Never ![IO, Exn]) ($msg) {
    say $msg;
    die($msg);
}
PERL

    is scalar @$errs, 0, 'IO + Exn builtins in ![IO, Exn] function — no error';
};

subtest 'effects: mixed builtins — Exn is ambient' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package MissingEffect;
use v5.40;

sub bail :sig((Str) -> Never ![IO]) ($msg) {
    say $msg;
    die($msg);
}
PERL

    is scalar @$errs, 0, 'Exn is ambient — no EffectMismatch even without ![Exn]';
};

# ── Decl effect: Typist declaration builtins ──

subtest 'effects: typedef in ![Decl] function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package TypedefDecl;
use v5.40;

sub setup :sig(() -> Void ![Decl]) () {
    typedef UserId => 'Int';
}
PERL

    is scalar @$errs, 0, 'typedef in ![Decl] function — no effect error';
};

subtest 'effects: typedef in pure function — Decl is ambient' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package TypedefPure;
use v5.40;

sub setup :sig(() -> Void) () {
    typedef UserId => 'Int';
}
PERL

    is scalar @$errs, 0, 'Decl is ambient — no EffectMismatch for typedef in pure function';
};

subtest 'effects: ->base is pure (method call, no effect)' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package BasePure;
use v5.40;

newtype UserId => 'Int';

sub extract :sig((UserId) -> Int) ($val) {
    $val->base;
}
PERL

    is scalar @$errs, 0, '->base in pure function — no effect error';
};

# ── New IO/Exn effects on core builtins ───────

subtest 'effects: rand in pure function — IO is ambient' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package RandPure;
use v5.40;

sub roll :sig(() -> Num) () {
    rand(6);
}
PERL

    is scalar @$errs, 0, 'IO is ambient — no EffectMismatch for rand in pure function';
};

subtest 'effects: time in pure function — IO is ambient' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package TimePure;
use v5.40;

sub now :sig(() -> Int) () {
    time();
}
PERL

    is scalar @$errs, 0, 'IO is ambient — no EffectMismatch for time in pure function';
};

subtest 'effects: sleep in pure function — IO is ambient' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package SleepPure;
use v5.40;

sub wait_a_bit :sig(() -> Int) () {
    sleep(1);
}
PERL

    is scalar @$errs, 0, 'IO is ambient — no EffectMismatch for sleep in pure function';
};

subtest 'effects: eval in pure function — Exn is ambient' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package EvalPure;
use v5.40;

sub try_it :sig((Any) -> Any) ($code) {
    eval($code);
}
PERL

    is scalar @$errs, 0, 'Exn is ambient — no EffectMismatch for eval in pure function';
};

subtest 'effects: exit in pure function — Exn is ambient' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package ExitPure;
use v5.40;

sub abort :sig(() -> Never) () {
    exit(1);
}
PERL

    is scalar @$errs, 0, 'Exn is ambient — no EffectMismatch for exit in pure function';
};

subtest 'effects: rand in ![IO] function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package RandIO;
use v5.40;

sub roll :sig(() -> Num ![IO]) () {
    rand(6);
}
PERL

    is scalar @$errs, 0, 'rand in ![IO] function — no effect error';
};

subtest 'effects: eval in ![Exn] function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package EvalExn;
use v5.40;

sub try_it :sig((Any) -> Any ![Exn]) ($code) {
    eval($code);
}
PERL

    is scalar @$errs, 0, 'eval in ![Exn] function — no effect error';
};

# ── struct builtin ────────────────────────────

subtest 'effects: struct in pure function — Decl is ambient' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package StructPure;
use v5.40;

sub define :sig(() -> Void) () {
    struct Point => ('x' => 'Int', 'y' => 'Int');
}
PERL

    is scalar @$errs, 0, 'Decl is ambient — no EffectMismatch for struct in pure function';
};

done_testing;
