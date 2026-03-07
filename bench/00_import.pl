#!/usr/bin/env perl
# Benchmark: Module import / load time
#
# Measures the cost of `use Typist` (static-only) vs `use Typist -runtime`.
# Runs as a subprocess to get clean module-load timing per iteration.
use v5.40;
use Time::HiRes 'gettimeofday', 'tv_interval';

my $lib = 'lib';
my $N   = 7;  # runs per config (take median)

sub _measure ($label, $code) {
    my @wall;
    for (1 .. $N) {
        my $t0 = [gettimeofday()];
        system($^X, "-I$lib", '-e', $code) == 0 or die "subprocess failed: $!";
        push @wall, tv_interval($t0);
    }
    @wall = sort { $a <=> $b } @wall;
    $wall[int($N / 2)];  # median
}

say "=" x 60;
say "  Import / Load Time";
say "=" x 60;
say "";

my $static  = _measure('static-only', 'use Typist');
my $runtime = _measure('-runtime',    'use Typist qw(-runtime)');

printf "  %-25s  %6.3f s  (median of %d runs)\n", 'use Typist',          $static,  $N;
printf "  %-25s  %6.3f s  (median of %d runs)\n", 'use Typist -runtime', $runtime, $N;
say    "  " . "-" x 50;
printf "  %-25s  %+.3f s  (%+.0f%%)\n", 'delta (runtime cost)',
    $runtime - $static,
    $static > 0 ? ($runtime - $static) / $static * 100 : 0;
say "";
