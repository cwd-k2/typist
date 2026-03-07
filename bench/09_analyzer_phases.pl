#!/usr/bin/env perl
# Benchmark: Analyzer phase breakdown
#
# Measures analyzer phase timings across one or more corpora, with warm-up and
# repeated runs so optimization decisions are less sensitive to a single corpus
# or a single noisy sample.
use v5.40;
use lib 'lib';

use File::Find ();
use Getopt::Long qw(GetOptions);

$ENV{TYPIST_CHECK_QUIET} = 1;

use Typist::Static::Analyzer;
use Typist::Static::Extractor;
use Typist::LSP::Workspace;

my %opts = (
    corpus => [],
    repeat => 5,
    warmup => 1,
);

GetOptions(
    'corpus=s@' => $opts{corpus},
    'repeat=i'  => \$opts{repeat},
    'warmup=i'  => \$opts{warmup},
) or die _usage();

die "--repeat must be >= 1\n" unless $opts{repeat} >= 1;
die "--warmup must be >= 0\n" unless $opts{warmup} >= 0;

my @corpora = _resolve_corpora($opts{corpus}->@*);
die "No benchmark corpora found\n" unless @corpora;

say "=" x 60;
say "  Analyzer Phase Breakdown";
say "=" x 60;
say "  repeat: $opts{repeat}";
say "  warmup: $opts{warmup}";
say "";

for my $corpus (@corpora) {
    _run_corpus($corpus, \%opts);
}

sub _usage {
    return <<'USAGE';
Usage: perl bench/09_analyzer_phases.pl [--corpus example|shop|mixed|PATH ...] [--repeat N] [--warmup N]

Examples:
  perl bench/09_analyzer_phases.pl
  perl bench/09_analyzer_phases.pl --corpus example --corpus shop --repeat 7 --warmup 2
  perl bench/09_analyzer_phases.pl --corpus ../some-project/lib
USAGE
}

sub _resolve_corpora (@specs) {
    @specs = ('mixed') unless @specs;

    my @corpora;
    for my $spec (@specs) {
        if ($spec eq 'example') {
            my @roots = grep { -e $_ } ('example');
            push @corpora, _make_corpus('example', \@roots) if @roots;
            next;
        }

        if ($spec eq 'shop') {
            my @roots = grep { -e $_ } ('../typist-example-shop/lib');
            push @corpora, _make_corpus('shop', \@roots) if @roots;
            next;
        }

        if ($spec eq 'mixed') {
            my @roots = grep { -e $_ } ('example', '../typist-example-shop/lib');
            push @corpora, _make_corpus('mixed', \@roots) if @roots;
            next;
        }

        push @corpora, _make_corpus($spec, [$spec]);
    }

    return grep { $_->{files}->@* } @corpora;
}

sub _make_corpus ($label, $roots) {
    my @files = _collect_files($roots->@*);
    return +{
        label => $label,
        roots => [@$roots],
        files => \@files,
    };
}

sub _run_corpus ($corpus, $opts) {
    my @files = $corpus->{files}->@*;
    return unless @files;

    say "-" x 60;
    say "  corpus: $corpus->{label}";
    say "  files:  " . scalar(@files);
    say "  roots:  " . join(', ', $corpus->{roots}->@*);
    say "";

    my $workspace_root = _workspace_root($corpus->{roots}->@*);
    my $ws = $workspace_root ? Typist::LSP::Workspace->new(root => $workspace_root) : undef;
    my $reg = $ws ? $ws->registry : undef;

    for (1 .. $opts->{warmup}) {
        _run_once(\@files, $reg);
    }

    my %samples;
    for (1 .. $opts->{repeat}) {
        my $timings = _run_once(\@files, $reg);
        for my $phase (keys %$timings) {
            push $samples{$phase}->@*, $timings->{$phase};
        }
    }

    for my $phase (_ordered_phases(keys %samples)) {
        my @values = $samples{$phase}->@*;
        printf "  %-34s %8.3f ms  [min %8.3f  max %8.3f]\n",
            $phase,
            _median(@values) * 1000,
            _min(@values) * 1000,
            _max(@values) * 1000;
    }

    say "";
}

sub _run_once ($files, $reg) {
    my %samples;

    for my $file ($files->@*) {
        open my $fh, '<:encoding(UTF-8)', $file or die "Cannot read $file: $!";
        my $source = do { local $/; <$fh> };
        close $fh;

        my $extracted = Typist::Static::Extractor->extract($source);
        my $result = Typist::Static::Analyzer->analyze(
            $source,
            file               => $file,
            extracted          => $extracted,
            ($reg ? (workspace_registry => $reg) : ()),
            collect_timing     => 1,
        );

        for my $phase (keys %{$result->{timings}}) {
            push $samples{$phase}->@*, $result->{timings}{$phase};
        }
    }

    my %summary;
    for my $phase (keys %samples) {
        $summary{$phase} = _median($samples{$phase}->@*);
    }
    return \%summary;
}

sub _collect_files (@roots) {
    my @files;
    for my $root (@roots) {
        next unless -e $root;
        if (-f $root && $root =~ /\.(?:pm|pl)\z/) {
            push @files, $root;
            next;
        }
        next unless -d $root;
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    return unless -f $_;
                    return unless /\.(?:pm|pl)\z/;
                    push @files, $File::Find::name;
                },
            },
            $root,
        );
    }
    return sort @files;
}

sub _workspace_root (@roots) {
    for my $root (@roots) {
        return $root if -d $root && $root =~ m{(?:^|/)lib/?\z};
    }
    return undef;
}

sub _median (@xs) {
    @xs = sort { $a <=> $b } @xs;
    return 0 unless @xs;
    return $xs[int(@xs / 2)];
}

sub _min (@xs) {
    @xs = sort { $a <=> $b } @xs;
    return 0 unless @xs;
    return $xs[0];
}

sub _max (@xs) {
    @xs = sort { $a <=> $b } @xs;
    return 0 unless @xs;
    return $xs[-1];
}

sub _ordered_phases (@phases) {
    my %rank = (
        extract                                => 10,
        registration                           => 20,
        visibility                             => 30,
        structural                             => 40,
        'structural.aliases'                   => 41,
        'structural.functions'                 => 42,
        'structural.functions.free_vars'       => 43,
        'structural.functions.undeclared_vars' => 44,
        'structural.functions.effects'         => 45,
        'structural.functions.bounds'          => 46,
        'structural.functions.type_wellformed' => 47,
        'structural.functions.kinds'           => 48,
        'structural.functions.total'           => 49,
        'structural.typeclasses'               => 50,
        'structural.protocols'                 => 51,
        type_env                               => 60,
        file_checks                            => 70,
        'file_checks.variables'                => 71,
        'file_checks.assignments'              => 72,
        'file_checks.call_sites'               => 73,
        'file_checks.match_exhaustiveness'     => 74,
        function_checks                        => 80,
        'function_checks.returns'              => 81,
        'function_checks.effects'              => 82,
        'function_checks.protocols'            => 83,
        'function_checks.handle_blocks'        => 84,
        collection                             => 90,
        diagnostics                            => 100,
        symbols                                => 110,
        total                                  => 999,
    );

    return sort {
        ($rank{$a} // 500) <=> ($rank{$b} // 500)
            || $a cmp $b
    } @phases;
}
