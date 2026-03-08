package Typist::Check;
use v5.40;

our $VERSION = '0.01';

use Getopt::Long ();
use File::Find   ();
use Cwd          ();

use Typist::LSP::Workspace;
use Typist::Static::Analyzer;

# ── Severity Classification ─────────────────────

my %SEVERITY_LABEL = (
    1 => 'error',
    2 => 'error',
    3 => 'warning',
    4 => 'warning',
    5 => 'hint',
);

# ── Public API ──────────────────────────────────

sub run ($class, @argv) {
    my $opts = _parse_args(\@argv);

    if ($opts->{help}) {
        _print_help();
        exit 0;
    }

    my $use_color = _should_color($opts);
    my $root      = _resolve_root($opts);
    my @files     = _collect_files($opts, $root);

    unless (@files) {
        say "No .pm files found.";
        exit 0;
    }

    # Build cross-file registry
    my $ws = Typist::LSP::Workspace->new(root => $root);

    # Analyze each file
    my @error_files;
    my $total_errors   = 0;
    my $total_warnings = 0;

    for my $file (sort @files) {
        open my $fh, '<:encoding(UTF-8)', $file or do {
            warn "Cannot open $file: $!\n";
            next;
        };
        my $source = do { local $/; <$fh> };
        close $fh;

        my $result = eval {
            Typist::Static::Analyzer->analyze(
                $source,
                workspace_registry => $ws->registry,
                file               => $file,
            );
        };
        if ($@) {
            warn "Analysis failed for $file: $@\n";
            next;
        }

        my $diags = $result->{diagnostics} // [];
        next unless @$diags || $opts->{verbose};

        if (@$diags) {
            push @error_files, $file;

            for my $d (@$diags) {
                my $sev = $d->{severity} // 3;
                if    ($sev <= 2) { $total_errors++ }
                elsif ($sev <= 4) { $total_warnings++ }
                # severity >= 5 (hints) are not counted in summary
            }
        }

        _print_file_diagnostics($file, $diags, $use_color, $opts->{verbose});
    }

    # Summary
    _print_summary(
        $total_errors, $total_warnings,
        scalar @error_files, scalar @files,
        $use_color,
    );

    # Exit code: 0 = clean, 1 = errors, 2 = warnings only
    if    ($total_errors > 0)   { exit 1 }
    elsif ($total_warnings > 0) { exit 2 }
    else                        { exit 0 }
}

# ── Argument Parsing ────────────────────────────

sub _parse_args ($argv) {
    my %opts;
    my $parser = Getopt::Long::Parser->new;
    $parser->configure('no_auto_abbrev', 'bundling');
    $parser->getoptionsfromarray(
        $argv,
        \%opts,
        'no-color',
        'verbose|v',
        'root=s',
        'help|h',
    );
    $opts{files} = [@$argv];
    \%opts;
}

# ── Color Control ───────────────────────────────

sub _should_color ($opts) {
    return 0 if $opts->{'no-color'};
    return 0 if defined $ENV{NO_COLOR};
    return 0 unless -t STDOUT;
    1;
}

sub _c ($code, $text, $use_color) {
    $use_color ? "\e[${code}m${text}\e[0m" : $text;
}

# ── Root Resolution ─────────────────────────────

sub _resolve_root ($opts) {
    if ($opts->{root}) {
        my $r = Cwd::abs_path($opts->{root});
        die "Root directory not found: $opts->{root}\n" unless $r && -d $r;
        return $r;
    }

    my $cwd = Cwd::getcwd();

    # Prefer lib/ if it exists
    my $lib = "$cwd/lib";
    return $lib if -d $lib;

    $cwd;
}

# ── File Collection ─────────────────────────────

sub _collect_files ($opts, $root) {
    my @explicit = ($opts->{files} // [])->@*;

    if (@explicit) {
        return map { Cwd::abs_path($_) // $_ } @explicit;
    }

    # Scan root for .pm files
    my @files;
    File::Find::find(sub {
        return unless /\.pm\z/ && -f;
        push @files, $File::Find::name;
    }, $root);

    @files;
}

# ── Output Formatting ──────────────────────────

sub _print_file_diagnostics ($file, $diags, $use_color, $verbose) {
    if (!@$diags) {
        # Verbose mode: show clean files
        if ($verbose) {
            say _c('2', $file, $use_color);  # dim
        }
        return;
    }

    say _c('1', $file, $use_color);  # bold

    for my $d (sort { $a->{line} <=> $b->{line} || $a->{col} <=> $b->{col} } @$diags) {
        my $sev   = $d->{severity} // 3;
        my $label = $SEVERITY_LABEL{$sev} // 'warning';
        my $kind  = $d->{kind} // 'Unknown';
        my $line  = $d->{line} // 0;
        my $col   = $d->{col}  // 1;

        # Hints (severity >= 5) only shown in verbose mode
        next if $sev >= 5 && !$verbose;

        my $loc   = sprintf '%4d:%-3d', $line, $col;
        my $colored_label = $label eq 'error'
            ? _c('31', $label, $use_color)       # red
            : $label eq 'hint'
            ? _c('36', $label, $use_color)       # cyan
            : _c('33', $label, $use_color);      # yellow
        my $colored_kind = _c('2', "[$kind]", $use_color);  # dim

        say "  $loc  $colored_label  $d->{message}  $colored_kind";
    }

    say '';  # blank line after file
}

sub _print_summary ($errors, $warnings, $error_files, $total_files, $use_color) {
    if ($errors == 0 && $warnings == 0) {
        say _c('32', "All clean.", $use_color) . " ($total_files file(s) checked)";
        return;
    }

    my @parts;
    push @parts, _c('31', "$errors error(s)", $use_color)     if $errors;
    push @parts, _c('33', "$warnings warning(s)", $use_color) if $warnings;

    my $summary = join(', ', @parts);
    $summary .= " in $error_files file(s)";
    $summary .= " ($total_files file(s) checked)";

    say $summary;
}

# ── Help ────────────────────────────────────────

sub _print_help () {
    print <<~'HELP';
    Usage: typist-check [OPTIONS] [FILES...]

    Static type checker for Perl files using Typist.

    If no files are specified, scans lib/ (or current directory) for .pm files.

    Options:
      --root DIR     Workspace root for cross-file resolution (default: lib/ or .)
      --no-color     Disable colored output
      -v, --verbose  Show clean files in output
      -h, --help     Show this help message

    Exit codes:
      0  All clean (no diagnostics)
      1  Errors found (severity 1-2)
      2  Warnings only (severity 3-4)

    Environment:
      NO_COLOR       Disable colored output (https://no-color.org)
    HELP
}

1;

=head1 NAME

Typist::Check - CLI driver for the typist-check static analysis tool

=head1 DESCRIPTION

Implements the C<typist-check> command-line interface. Scans Perl module files,
runs L<Typist::Static::Analyzer> with cross-file resolution via
L<Typist::LSP::Workspace>, and prints colorized diagnostics with severity
classification. Exit codes: C<0> (clean), C<1> (errors), C<2> (warnings only).

=head2 run

    Typist::Check->run(@ARGV);

Entry point for the CLI. Parses command-line options (C<--root>, C<--no-color>,
C<--verbose>, C<--help>), collects C<.pm> files from the workspace root or
explicit file arguments, analyzes each file, and prints diagnostics with a
summary line. Calls C<exit> with the appropriate exit code.

=cut
