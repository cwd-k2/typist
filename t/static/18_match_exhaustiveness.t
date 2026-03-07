use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;

sub diags_of ($source, $kind) {
    my $result = Typist::Static::Analyzer->analyze($source);
    [ grep { $_->{kind} eq $kind } $result->{diagnostics}->@* ];
}

subtest 'missing variant without fallback emits diagnostic' => sub {
    my $errs = diags_of(<<'PERL', 'NonExhaustiveMatch');
use v5.40;
datatype State => Ready => '()', Busy => '()';
my $s = Ready();
my $x :sig(Int) = match $s,
    Ready => sub { 1 };
PERL

    is scalar @$errs, 1, 'one exhaustiveness diagnostic';
    like $errs->[0]{message}, qr/Busy/, 'missing variant named in message';
};

subtest 'all variants covered is clean without fallback' => sub {
    my $errs = diags_of(<<'PERL', 'NonExhaustiveMatch');
use v5.40;
datatype State => Ready => '()', Busy => '()';
my $s = Ready();
my $x :sig(Int) = match $s,
    Ready => sub { 1 },
    Busy  => sub { 2 };
PERL

    is scalar @$errs, 0, 'no diagnostic when all variants are present';
};

subtest 'fallback arm suppresses diagnostic' => sub {
    my $errs = diags_of(<<'PERL', 'NonExhaustiveMatch');
use v5.40;
datatype State => Ready => '()', Busy => '()';
my $s = Ready();
my $x :sig(Int) = match $s,
    Ready => sub { 1 },
    _     => sub { 0 };
PERL

    is scalar @$errs, 0, 'no diagnostic with fallback arm';
};

done_testing;
