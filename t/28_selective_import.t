use v5.40;
use Test::More;
use lib 'lib';
use File::Temp 'tempfile';

# Helper: run Perl code in a subprocess, return stdout+stderr
sub run_perl ($code) {
    my ($fh, $file) = tempfile(SUFFIX => '.pl', UNLINK => 1);
    print $fh $code;
    close $fh;
    my $out = `$^X $file 2>&1`;
    $out;
}

# ── Typist::DSL selective import (recommended path) ──

subtest 'use Typist::DSL qw(Int Str) — selected DSL names available' => sub {
    my $out = run_perl(<<'PERL');
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL qw(Int Str);
print ref(Int), "\n";
print ref(Str), "\n";
PERL

    like $out, qr/Typist::Type::Atom/, 'Int is available via Typist::DSL';
    unlike $out, qr/deprecated/, 'no deprecation warning';
};

subtest 'use Typist::DSL qw(optional Int) — optional is importable' => sub {
    my $out = run_perl(<<'PERL');
use v5.40;
use lib 'lib';
use Typist;
use Typist::DSL qw(optional Int);
my $o = optional(Int);
print ref($o), "\n";
PERL

    like $out, qr/Typist::DSL::Optional/, 'optional() available via Typist::DSL';
};

# ── Rejected path: use Typist qw(...) ──

subtest 'use Typist qw(Int) — dies with clear message' => sub {
    my $out = run_perl(<<'PERL');
use v5.40;
use lib 'lib';
eval { require Typist; Typist->import('Int') };
print $@ ? "died: $@" : "ok\n";
PERL

    like $out, qr/died/, 'use Typist qw(Int) dies';
    like $out, qr/Typist::DSL/, 'error message mentions Typist::DSL';
};

subtest 'use Typist — bare import does not export DSL names' => sub {
    my $out = run_perl(<<'PERL');
use v5.40;
use lib 'lib';
use Typist;
eval { Int() };
print $@ ? "not_found\n" : "found\n";
PERL

    like $out, qr/not_found/, 'Int is NOT available with bare use Typist';
};

subtest 'use Typist qw(NotAType) — dies on any DSL-like name' => sub {
    my $out = run_perl(<<'PERL');
use v5.40;
use lib 'lib';
eval { require Typist; Typist->import('NotAType') };
print $@ ? "died\n" : "ok\n";
PERL

    like $out, qr/died/, 'any uppercase arg causes die';
};

subtest 'use Typist -runtime — runtime flag with bare import' => sub {
    my $out = run_perl(<<'PERL');
use v5.40;
use lib 'lib';
use Typist -runtime;
print $Typist::RUNTIME ? "runtime\n" : "static\n";
PERL

    like $out, qr/runtime/, 'runtime flag is set';
    unlike $out, qr/deprecated/, 'no deprecation warning for -runtime';
};

subtest 'core functions always exported' => sub {
    my $out = run_perl(<<'PERL');
use v5.40;
use lib 'lib';
use Typist;
print defined(&typedef)  ? "yes\n" : "no\n";
print defined(&newtype)  ? "yes\n" : "no\n";
print defined(&effect)   ? "yes\n" : "no\n";
print defined(&handle)   ? "yes\n" : "no\n";
print defined(&match)    ? "yes\n" : "no\n";
print defined(&struct)   ? "yes\n" : "no\n";
PERL

    my @lines = split /\n/, $out;
    is_deeply \@lines, [('yes') x 6], 'all core functions exported with bare use Typist';
};

done_testing;
