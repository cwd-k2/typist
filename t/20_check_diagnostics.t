use v5.40;
use Test::More;
use File::Temp qw(tempfile);

# CHECK blocks run once per process, so we test via subprocesses.

my $perl = $^X;

# ── Static-only mode: CHECK detects TypeMismatch ──

subtest 'CHECK detects TypeMismatch in static-only mode' => sub {
    my $out = _run_perl_code(<<'PERL');
use v5.40;
use Typist;

sub greet :sig((Str) -> Str) ($name) { "Hello, $name!" }

greet(42);
PERL

    like $out->{stderr}, qr/TypeMismatch/, 'CHECK reports TypeMismatch';
    is $out->{exit}, 0, 'process exits 0 (warn, not die)';
};

# ── Static-only mode: CHECK detects EffectMismatch ──

subtest 'CHECK detects EffectMismatch in static-only mode' => sub {
    my $out = _run_perl_code(<<'PERL');
use v5.40;
use Typist;

BEGIN {
    effect Console => +{ writeLine => 'CodeRef[Str -> Void]' };
    effect DB      => +{ query     => 'CodeRef[Str -> Any]'  };
}

sub db_op :sig((Str) -> Str ![DB]) ($q) { $q }
sub handler :sig(() -> Str ![Console]) () { db_op("SELECT 1") }

handler();
PERL

    like $out->{stderr}, qr/EffectMismatch/, 'CHECK reports EffectMismatch';
    is $out->{exit}, 0, 'process exits 0 (warn, not die)';
};

# ── Static-only mode: no runtime die ──

subtest 'static-only mode does not die on type error at runtime' => sub {
    my $out = _run_perl_code(<<'PERL');
use v5.40;
use Typist;

sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }

eval { add("x", 3) };
print $@ ? "DIED" : "OK";
PERL

    like $out->{stdout}, qr/OK/, 'no runtime die in static-only mode';
};

# ── -runtime flag enables runtime enforcement ──

subtest '-runtime flag enables runtime die' => sub {
    my $out = _run_perl_code(<<'PERL');
use v5.40;
use Typist -runtime;

sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }

eval { add("x", 3) };
print $@ ? "DIED" : "OK";
PERL

    like $out->{stdout}, qr/DIED/, '-runtime enables runtime enforcement';
};

# ── TYPIST_RUNTIME=1 env var ──

subtest 'TYPIST_RUNTIME=1 env enables runtime die' => sub {
    my $out = _run_perl_code(<<'PERL', env => +{ TYPIST_RUNTIME => 1 });
use v5.40;
use Typist;

sub add :sig((Int, Int) -> Int) ($a, $b) { $a + $b }

eval { add("x", 3) };
print $@ ? "DIED" : "OK";
PERL

    like $out->{stdout}, qr/DIED/, 'TYPIST_RUNTIME=1 enables runtime enforcement';
};

# ── Scalar tie conditional ──

subtest 'scalar tie only in runtime mode' => sub {
    my $code = <<'PERL';
use v5.40;
use Typist;

my $x :sig(Int) = 42;
eval { $x = "hello" };
print $@ ? "DIED" : "OK";
PERL

    my $out_static  = _run_perl_code($code);
    my $out_runtime = _run_perl_code($code, env => +{ TYPIST_RUNTIME => 1 });

    like $out_static->{stdout},  qr/OK/,   'static-only: no tie enforcement';
    like $out_runtime->{stdout}, qr/DIED/, 'runtime: tie enforces';
};

# ── TYPIST_CHECK_QUIET suppresses CHECK output ──

subtest 'CHECK_QUIET suppresses warn and skips Analyzer' => sub {
    my $code = <<'PERL';
use v5.40;
use Typist;

sub greet :sig((Str) -> Str) ($name) { "Hello, $name!" }

greet(42);
print "DONE";
PERL

    my $out_normal = _run_perl_code($code);
    my $out_quiet  = _run_perl_code($code, env => +{ TYPIST_CHECK_QUIET => 1 });

    like   $out_normal->{stderr}, qr/TypeMismatch/, 'normal: CHECK warns';
    unlike $out_quiet->{stderr},  qr/TypeMismatch/, 'quiet: CHECK silent';
    like   $out_quiet->{stdout},  qr/DONE/,         'quiet: script runs normally';
};

done_testing;

# ── Helper ────────────────────────────────────────

sub _run_perl_code ($code, %opts) {
    my ($fh, $filename) = tempfile(SUFFIX => '.pl', UNLINK => 1);
    print $fh $code;
    close $fh;

    my %env = ($opts{env} // +{})->%*;

    # Build env prefix for shell
    my $env_prefix = join(' ', map { "$_=$env{$_}" } keys %env);
    $env_prefix .= ' ' if $env_prefix;

    my $cmd_base = "${env_prefix}${perl} -Ilib $filename";

    # Capture stdout (stderr to /dev/null)
    my $stdout = `$cmd_base 2>/dev/null`;
    my $exit   = $? >> 8;

    # Capture stderr (stdout to /dev/null)
    my $stderr = `$cmd_base 2>&1 1>/dev/null`;

    +{ stdout => $stdout, stderr => $stderr, exit => $exit };
}
