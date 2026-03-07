#!/usr/bin/env perl
# Benchmark: Analyzer phase breakdown
#
# Measures median wall time for each Analyzer phase on a corpus of files.
# Default corpus is example/ plus a sibling typist-example-shop checkout if present.
use v5.40;
use lib 'lib';

use File::Find ();
use File::Spec ();

$ENV{TYPIST_CHECK_QUIET} = 1;

use Typist::Static::Analyzer;
use Typist::Static::Extractor;
use Typist::LSP::Workspace;

my @roots = @ARGV ? @ARGV : _default_roots();
my @files = _collect_files(@roots);
die "No benchmark files found\n" unless @files;

say "=" x 60;
say "  Analyzer Phase Breakdown";
say "=" x 60;
say "  corpus: " . scalar(@files) . " file(s)";
say "";

my $workspace_root = _workspace_root(@roots);
my $ws = $workspace_root ? Typist::LSP::Workspace->new(root => $workspace_root) : undef;
my $reg = $ws ? $ws->registry : undef;

my %samples;

for my $file (@files) {
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

    for my $phase (sort keys %{$result->{timings}}) {
        push @{$samples{$phase} //= []}, $result->{timings}{$phase};
    }
}

for my $phase (sort {
    ($a eq 'total' ? 1 : 0) <=> ($b eq 'total' ? 1 : 0) || $a cmp $b
} keys %samples) {
    my $median = _median(@{$samples{$phase}});
    printf "  %-18s %8.3f ms\n", $phase, $median * 1000;
}

say "";

sub _default_roots {
    my @roots = ('example');
    push @roots, '../typist-example-shop/lib' if -d '../typist-example-shop/lib';
    @roots;
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
    sort @files;
}

sub _workspace_root (@roots) {
    for my $root (@roots) {
        return $root if -d $root && $root =~ m{(?:^|/)lib/?\z};
    }
    undef;
}

sub _median (@xs) {
    @xs = sort { $a <=> $b } @xs;
    return 0 unless @xs;
    return $xs[int(@xs / 2)];
}
