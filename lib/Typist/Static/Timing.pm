package Typist::Static::Timing;
use v5.40;

our $VERSION = '0.01';

use B ();
use Scalar::Util qw(refaddr);
use Time::HiRes qw(time);

our @EXPORT_OK = qw(
    start_timing
    record_timing
    accumulate_timing
    merge_prefixed_timings
    finish_total_timing
);

my @PENDING_WRAP;

sub import ($class, @symbols) {
    my $caller = caller;
    $class->install($caller);
    no strict 'refs';
    for my $symbol (@symbols) {
        next unless grep { $_ eq $symbol } @EXPORT_OK;
        *{"${caller}::${symbol}"} = \&{$symbol};
    }
}

sub install ($class, $target) {
    no strict 'refs';
    *{"${target}::MODIFY_CODE_ATTRIBUTES"} = \&_handle_code_attrs;
    *{"${target}::FETCH_CODE_ATTRIBUTES"}  = sub { () };
}

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

sub _handle_code_attrs ($pkg, $coderef, @attrs) {
    my @unhandled;
    for my $attr (@attrs) {
        if ($attr =~ /\A(TIMED|TIMED_ACC)(?:\(([^()]*)\))?\z/) {
            my ($mode, $name) = ($1, $2);
            my $spec = [$pkg, $coderef, $name, $mode eq 'TIMED_ACC'];
            if (!_wrap_timed_sub($spec->@*)) {
                push @PENDING_WRAP, $spec;
            }
            next;
        }
        push @unhandled, $attr;
    }
    @unhandled;
}

sub _wrap_timed_sub ($pkg, $coderef, $timing_name, $accumulate) {
    my $name = _recover_name($pkg, $coderef) // return;
    $timing_name //= $name;
    no strict 'refs';
    no warnings 'redefine';
    my $original = *{"${pkg}::${name}"}{CODE} // $coderef;
    *{"${pkg}::${name}"} = sub {
        my @args = @_;
        my $timings = ref($args[0]) ? eval { $args[0]{timings} } : undef;
        my $t0 = start_timing($timings);

        if (wantarray) {
            my @result = $original->(@args);
            ($accumulate ? \&accumulate_timing : \&record_timing)->($timings, $timing_name, $t0);
            return @result;
        }
        if (defined wantarray) {
            my $result = $original->(@args);
            ($accumulate ? \&accumulate_timing : \&record_timing)->($timings, $timing_name, $t0);
            return $result;
        }

        $original->(@args);
        ($accumulate ? \&accumulate_timing : \&record_timing)->($timings, $timing_name, $t0);
        return;
    };
}

sub _recover_name ($pkg, $coderef) {
    my $cv = B::svref_2object($coderef);
    my $gv = eval { $cv->GV };
    if ($gv && $$gv) {
        my $name = eval { $gv->NAME };
        return $name if defined $name && length $name && $name ne '__ANON__';
    }

    no strict 'refs';
    my $stash = \%{"${pkg}::"};
    my $target = refaddr($coderef);
    for my $name (keys %$stash) {
        my $candidate = *{"${pkg}::${name}"}{CODE} or next;
        return $name if refaddr($candidate) == $target;
    }

    return undef;
}

1;
