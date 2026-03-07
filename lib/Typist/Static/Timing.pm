package Typist::Static::Timing;
use v5.40;

our $VERSION = '0.01';

use Exporter 'import';
use Time::HiRes qw(time);

our @EXPORT_OK = qw(
    start_timing
    record_timing
    accumulate_timing
    merge_prefixed_timings
    finish_total_timing
);

sub start_timing ($timings) {
    return undef unless $timings;
    return time();
}

sub record_timing ($timings, $name, $started_at) {
    return unless $timings && defined $started_at;
    $timings->{$name} = time() - $started_at;
}

sub accumulate_timing ($timings, $name, $started_at) {
    return unless $timings && defined $started_at;
    $timings->{$name} += time() - $started_at;
}

sub merge_prefixed_timings ($timings, $prefix, $nested) {
    return unless $timings && $nested;
    for my $name (keys %$nested) {
        $timings->{"$prefix.$name"} = $nested->{$name};
    }
}

sub finish_total_timing ($timings, $started_at) {
    return unless $timings && defined $started_at;
    $timings->{total} = time() - $started_at;
}

1;
