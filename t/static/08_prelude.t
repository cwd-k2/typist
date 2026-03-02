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

sub io_fn :Type(() -> Void ![IO]) () { }
sub exn_fn :Type(() -> Void ![Exn]) () { }
sub decl_fn :Type(() -> Void ![Decl]) () { }
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

subtest 'effects: say in ![IO] function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package SayInIO;
use v5.40;

sub greet :Type((Str) -> Void ![IO]) ($name) {
    say "Hello, $name";
}
PERL

    is scalar @$errs, 0, 'say in ![IO] function — no effect error';
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

subtest 'effects: die in ![Exn] function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package DieInExn;
use v5.40;

sub fail :Type((Str) -> Never ![Exn]) ($msg) {
    die($msg);
}
PERL

    is scalar @$errs, 0, 'die in ![Exn] function — no effect error';
};

subtest 'effects: die in ![IO] function → EffectMismatch' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package DieInIO;
use v5.40;

sub io_only :Type((Str) -> Void ![IO]) ($msg) {
    die($msg);
}
PERL

    ok scalar @$errs > 0, 'die in ![IO] function flagged (needs Exn)';
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

declare say => '(Str) -> Void ![Console]';

sub greet :Type((Str) -> Void ![Console]) ($name) {
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

sub verbose :Type((Str) -> Void ![IO]) ($msg) {
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

sub bail :Type((Str) -> Never ![IO, Exn]) ($msg) {
    say $msg;
    die($msg);
}
PERL

    is scalar @$errs, 0, 'IO + Exn builtins in ![IO, Exn] function — no error';
};

subtest 'effects: mixed builtins missing one effect → flagged' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package MissingEffect;
use v5.40;

sub bail :Type((Str) -> Never ![IO]) ($msg) {
    say $msg;
    die($msg);
}
PERL

    ok scalar @$errs > 0, 'die requires Exn, caller only has IO';
    like $errs->[0]{message}, qr/Exn/, 'reports missing Exn effect';
};

# ── Decl effect: Typist declaration builtins ──

subtest 'effects: typedef in ![Decl] function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package TypedefDecl;
use v5.40;

sub setup :Type(() -> Void ![Decl]) () {
    typedef UserId => 'Int';
}
PERL

    is scalar @$errs, 0, 'typedef in ![Decl] function — no effect error';
};

subtest 'effects: typedef in pure function → EffectMismatch' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package TypedefPure;
use v5.40;

sub setup :Type(() -> Void) () {
    typedef UserId => 'Int';
}
PERL

    ok scalar @$errs > 0, 'typedef in pure function flagged';
    like $errs->[0]{message}, qr/Decl/, 'reports Decl effect requirement';
};

subtest 'effects: unwrap remains pure' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package UnwrapPure;
use v5.40;

sub extract :Type((Any) -> Any) ($val) {
    unwrap($val);
}
PERL

    is scalar @$errs, 0, 'unwrap in pure function — no effect error (remains pure)';
};

# ── New IO/Exn effects on core builtins ───────

subtest 'effects: rand requires IO' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package RandPure;
use v5.40;

sub roll :Type(() -> Num) () {
    rand(6);
}
PERL

    ok scalar @$errs > 0, 'rand in pure function flagged';
    like $errs->[0]{message}, qr/IO/, 'reports IO effect requirement for rand';
};

subtest 'effects: time requires IO' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package TimePure;
use v5.40;

sub now :Type(() -> Int) () {
    time();
}
PERL

    ok scalar @$errs > 0, 'time in pure function flagged';
    like $errs->[0]{message}, qr/IO/, 'reports IO effect requirement for time';
};

subtest 'effects: sleep requires IO' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package SleepPure;
use v5.40;

sub wait_a_bit :Type(() -> Int) () {
    sleep(1);
}
PERL

    ok scalar @$errs > 0, 'sleep in pure function flagged';
    like $errs->[0]{message}, qr/IO/, 'reports IO effect requirement for sleep';
};

subtest 'effects: eval requires Exn' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package EvalPure;
use v5.40;

sub try_it :Type((Any) -> Any) ($code) {
    eval($code);
}
PERL

    ok scalar @$errs > 0, 'eval in pure function flagged';
    like $errs->[0]{message}, qr/Exn/, 'reports Exn effect requirement for eval';
};

subtest 'effects: exit requires Exn' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package ExitPure;
use v5.40;

sub abort :Type(() -> Never) () {
    exit(1);
}
PERL

    ok scalar @$errs > 0, 'exit in pure function flagged';
    like $errs->[0]{message}, qr/Exn/, 'reports Exn effect requirement for exit';
};

subtest 'effects: rand in ![IO] function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package RandIO;
use v5.40;

sub roll :Type(() -> Num ![IO]) () {
    rand(6);
}
PERL

    is scalar @$errs, 0, 'rand in ![IO] function — no effect error';
};

subtest 'effects: eval in ![Exn] function → no error' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package EvalExn;
use v5.40;

sub try_it :Type((Any) -> Any ![Exn]) ($code) {
    eval($code);
}
PERL

    is scalar @$errs, 0, 'eval in ![Exn] function — no effect error';
};

# ── struct builtin ────────────────────────────

subtest 'effects: struct requires Decl' => sub {
    my $errs = diags_of(<<'PERL', 'EffectMismatch');
package StructPure;
use v5.40;

sub define :Type(() -> Void) () {
    struct Point => ('x' => 'Int', 'y' => 'Int');
}
PERL

    ok scalar @$errs > 0, 'struct in pure function flagged';
    like $errs->[0]{message}, qr/Decl/, 'reports Decl effect requirement for struct';
};

done_testing;
