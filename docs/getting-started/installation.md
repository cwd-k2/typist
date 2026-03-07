# Installation

!!! warning "Not on CPAN"
    There is an unrelated module named `Typist` on CPAN — it is **not** this project. This Typist is distributed exclusively via its [GitHub repository](https://github.com/cwd-k2/typist).

## Prerequisites

- **Perl 5.40 or later.**
- **[cpanm](https://metacpan.org/pod/App::cpanminus)** (recommended for installation).

All other dependencies (PPI, JSON::PP) are resolved automatically.

## Install

### cpanm (recommended)

```sh
cpanm https://github.com/cwd-k2/typist.git
```

This installs the `Typist` module, along with the `typist-check` and `typist-lsp` CLI tools.

### Local install (per-project)

If you prefer to install into a project-local directory:

```sh
cpanm -L local https://github.com/cwd-k2/typist.git
```

Then run your scripts with the local library path:

```sh
perl -Ilocal/lib/perl5 -Ilib your_script.pl
```

### Carton

Add to your `cpanfile`:

```perl
requires 'Typist';
```

Then:

```sh
cpanm -L local https://github.com/cwd-k2/typist.git
```

!!! note
    Since Typist is not on CPAN, `carton install` alone cannot resolve it. Install Typist with `cpanm` first, then Carton will recognize it in `local/`.

### From source

```sh
git clone https://github.com/cwd-k2/typist.git
cd typist
perl Makefile.PL
make && make test
make install
```

## Verify

After installation, confirm that Typist is working:

```sh
perl -e 'use Typist; say "ok"'
```

Check that the CLI tools are available:

```sh
typist-check --help
typist-lsp --help
```

If you used `-L local`, use the full paths instead:

```sh
perl -Ilocal/lib/perl5 -e 'use Typist; say "ok"'
local/bin/typist-check --help
```

## Project Setup

A typical Typist project looks like this:

```
my-project/
  lib/
    MyApp/
      Types.pm        # Type definitions (typedef, struct, effect, ...)
      Logic.pm        # Business logic with :sig() annotations
  script/
    app.pl            # Entry point
  cpanfile            # Dependencies
```

Your `cpanfile`:

```perl
requires 'perl', 'v5.40';
requires 'Typist';
```

Your type definitions module (`lib/MyApp/Types.pm`):

```perl
package MyApp::Types;
use v5.40;
use Typist;
use Exporter 'import';

our @EXPORT = qw(Name Email);

BEGIN {
    newtype Name  => 'Str';
    newtype Email => 'Str';

    struct User => (
        name  => 'Name',
        email => 'Email',
    );
}

1;
```

Your application code (`lib/MyApp/Logic.pm`):

```perl
package MyApp::Logic;
use v5.40;
use Typist;
use MyApp::Types;

sub greet :sig((User) -> Str) ($user) {
    "Hello, " . $user->name . "!";
}

1;
```

## Static Analysis

Run `typist-check` against your project:

```sh
typist-check                     # Scans lib/ by default
typist-check lib/MyApp/Logic.pm  # Check specific files
typist-check --verbose           # Show clean files too
```

See [typist-check CLI](../tooling/typist-check.md) for the full option reference.

## Next Steps

With everything installed, proceed to [First Program](first-program.md) to walk through a complete typed program step by step.
