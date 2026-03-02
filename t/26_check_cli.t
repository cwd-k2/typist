use v5.40;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $perl = $^X;
my $bin  = 'bin/typist-check';

# ── Helper ──────────────────────────────────────

sub _write_file ($dir, $name, $content) {
    my $path = "$dir/$name";
    my $parent = $path =~ s|/[^/]+$||r;
    make_path($parent) unless -d $parent;
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot write $path: $!";
    print $fh $content;
    close $fh;
    $path;
}

sub _run_check (@args) {
    my $cmd = join(' ', $perl, '-Ilib', $bin, @args);
    my $stdout = `$cmd 2>/dev/null`;
    my $exit   = $? >> 8;
    my $stderr = `$cmd 2>&1 1>/dev/null`;
    +{ stdout => $stdout, stderr => $stderr, exit => $exit };
}

# ── Clean file → exit 0 ────────────────────────

subtest 'clean file exits 0 with All clean' => sub {
    my $dir = tempdir(CLEANUP => 1);
    _write_file($dir, 'Clean.pm', <<~'PERL');
    package Clean;
    use v5.40;
    use Typist;

    sub add :Type((Int, Int) -> Int) ($a, $b) { $a + $b }

    1;
    PERL

    my $out = _run_check('--root', $dir, '--no-color');
    is $out->{exit}, 0, 'exit code 0';
    like $out->{stdout}, qr/All clean/, 'says All clean';
};

# ── TypeMismatch → exit 1 ──────────────────────

subtest 'TypeMismatch detected exits 1' => sub {
    my $dir = tempdir(CLEANUP => 1);
    _write_file($dir, 'Bad.pm', <<~'PERL');
    package Bad;
    use v5.40;
    use Typist;

    sub greet :Type((Str) -> Str) ($name) { "Hello, $name!" }

    my $x :Type(Str) = greet(42);

    1;
    PERL

    my $out = _run_check('--root', $dir, '--no-color');
    is $out->{exit}, 1, 'exit code 1 for errors';
    like $out->{stdout}, qr/error/, 'output contains error';
    like $out->{stdout}, qr/TypeMismatch/, 'output contains TypeMismatch';
};

# ── Warning only → exit 2 ──────────────────────

subtest 'warning only exits 2' => sub {
    my $dir = tempdir(CLEANUP => 1);
    _write_file($dir, 'Warn.pm', <<~'PERL');
    package Warn;
    use v5.40;
    use Typist;

    sub foo :Type(<T>(T) -> Q) ($x) { $x }

    1;
    PERL

    my $out = _run_check('--root', $dir, '--no-color');
    is $out->{exit}, 2, 'exit code 2 for warnings only';
    like $out->{stdout}, qr/warning/, 'output contains warning';
};

# ── --no-color → no ANSI codes ─────────────────

subtest '--no-color disables ANSI' => sub {
    my $dir = tempdir(CLEANUP => 1);
    _write_file($dir, 'Err.pm', <<~'PERL');
    package Err;
    use v5.40;
    use Typist;

    sub greet :Type((Str) -> Str) ($name) { "Hello, $name!" }

    my $x :Type(Str) = greet(42);

    1;
    PERL

    my $out = _run_check('--root', $dir, '--no-color');
    unlike $out->{stdout}, qr/\e\[/, 'no ANSI escape codes in output';
};

# ── --verbose → clean files shown ──────────────

subtest '--verbose shows clean files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    _write_file($dir, 'Ok.pm', <<~'PERL');
    package Ok;
    use v5.40;
    use Typist;

    sub id :Type((Int) -> Int) ($x) { $x }

    1;
    PERL

    my $out = _run_check('--root', $dir, '--no-color', '--verbose');
    is $out->{exit}, 0, 'exit code 0';
    like $out->{stdout}, qr/Ok\.pm/, 'clean file name in verbose output';
};

# ── File arguments → only specified files ──────

subtest 'explicit file arguments' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $good = _write_file($dir, 'Good.pm', <<~'PERL');
    package Good;
    use v5.40;
    use Typist;

    sub id :Type((Int) -> Int) ($x) { $x }

    1;
    PERL

    my $bad = _write_file($dir, 'Bad2.pm', <<~'PERL');
    package Bad2;
    use v5.40;
    use Typist;

    sub greet :Type((Str) -> Str) ($name) { "Hello, $name!" }

    my $x :Type(Str) = greet(42);

    1;
    PERL

    # Check only the good file
    my $out = _run_check('--root', $dir, '--no-color', $good);
    is $out->{exit}, 0, 'exit 0 when only checking clean file';
    unlike $out->{stdout}, qr/Bad2/, 'bad file not in output';
};

# ── --help ─────────────────────────────────────

subtest '--help prints usage' => sub {
    my $out = _run_check('--help');
    is $out->{exit}, 0, 'exit code 0';
    like $out->{stdout}, qr/Usage:/, 'contains Usage';
    like $out->{stdout}, qr/--no-color/, 'mentions --no-color';
};

done_testing;
