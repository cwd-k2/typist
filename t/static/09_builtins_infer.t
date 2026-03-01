use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;

# Helper: analyze source, return diagnostics of a given kind
sub diags_of ($source, $kind) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq $kind } $result->{diagnostics}->@* ];
}

# ── handle return type inference ─────────────────

subtest 'handle: infer Int from block body' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Int) = handle { 42 } Console => +{ log => sub ($msg) {} };
PERL

    is scalar @$errs, 0, 'handle block returns Int, assigned to Int — no error';
};

subtest 'handle: type mismatch (block returns Int, var expects Str)' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Str) = handle { 42 } Console => +{ log => sub ($msg) {} };
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/\$x.*Str.*\b42\b/i, 'expected Str, got 42 (Int literal)';
};

subtest 'handle: infer Str from string expression' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Str) = handle { "hello" } Console => +{ log => sub ($msg) {} };
PERL

    is scalar @$errs, 0, 'handle block returns Str — no error';
};

# ── match return type inference ──────────────────

subtest 'match: infer Int from same-type arms' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $val = bless +{ _tag => 'A', _values => [] }, 'Typist::Data::TestADT';
my $x :Type(Int) = match $val,
    A => sub { 1 },
    B => sub { 2 };
PERL

    is scalar @$errs, 0, 'all arms return Int — no error';
};

subtest 'match: type mismatch (arms return Int, var expects Str)' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $val = bless +{ _tag => 'A', _values => [] }, 'Typist::Data::TestADT';
my $x :Type(Str) = match $val,
    A => sub { 1 },
    B => sub { 2 };
PERL

    is scalar @$errs, 1, 'one type error';
    like $errs->[0]{message}, qr/\$x.*Str.*Int/i, 'expected Str, got Int';
};

subtest 'match: mixed types produce union (Int | Str)' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $val = bless +{ _tag => 'A', _values => [] }, 'Typist::Data::TestADT';
my $x :Type(Int | Str) = match $val,
    A => sub { 42 },
    B => sub { "hello" };
PERL

    is scalar @$errs, 0, 'mixed arms (Int | Str) assigned to Int | Str — no error';
};

# ── unwrap CORE registration ─────────────

subtest 'unwrap: registered as CORE builtin (returns Any)' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Int) = unwrap(42);
PERL

    is scalar @$errs, 0, 'unwrap returns Any — gradual skip, no error';
};

# ── declaration functions return Void ────────────

subtest 'typedef: registered as CORE builtin' => sub {
    my $errs = diags_of(<<'PERL', 'TypeMismatch');
use v5.40;
my $x :Type(Void) = typedef(Name => 'Int');
PERL

    is scalar @$errs, 0, 'typedef returns Void — no error';
};

done_testing;
