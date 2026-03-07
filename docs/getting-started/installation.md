# Installation

!!! warning "Not on CPAN"
    There is an unrelated module named `Typist` on CPAN — it is **not** this project. This Typist is distributed exclusively via its [GitHub repository](https://github.com/cwd-k2/typist). Clone or download from there.

## Prerequisites

Typist requires:

- **Perl 5.40 or later.** The project's `.perl-version` targets 5.42.0 (managed via [plenv](https://github.com/tokuhirom/plenv)), but any 5.40+ release works.
- **[PPI](https://metacpan.org/pod/PPI)** -- the Perl document parser that powers Typist's static analysis engine.
- **[JSON::PP](https://metacpan.org/pod/JSON::PP)** -- used by the LSP transport layer. This module ships with Perl core since 5.14, so you likely already have it.

Optional:

- **[Perl::Critic](https://metacpan.org/pod/Perl::Critic)** -- enables additional lint-style policies (effect completeness, match exhaustiveness, annotation style).

## Installation Methods

### Via Carton (recommended)

The repository includes a `cpanfile` that declares all dependencies. [Carton](https://metacpan.org/pod/Carton) installs them into a local `local/` directory, keeping your system Perl clean.

```sh
# Install Carton if you don't have it
cpanm Carton

# Install project dependencies
carton install
```

If you use [mise](https://mise.jdx.dev/), the project provides a task alias:

```sh
mise run deps
```

This runs `carton install` under the hood.

### Direct CPAN install

If you prefer a global installation:

```sh
cpanm PPI
cpanm Perl::Critic    # optional
```

## Verification

Run these three checks to confirm everything is working.

### 1. Module loads

```sh
perl -Ilib -e 'use Typist; say "ok"'
```

You should see `ok` printed to stdout. If Perl cannot find `PPI`, you will get a compilation error here.

### 2. CLI checker runs

```sh
perl -Ilib bin/typist-check --help
```

This prints the usage summary for `typist-check`, the command-line static analysis tool.

### 3. An example runs cleanly

```sh
perl -Ilib example/01_foundations.pl
```

This runs the foundations example, which exercises type aliases, typed variables, and typed subroutines. You should see output demonstrating successful type-checked execution.

### When using Carton

If you installed dependencies via Carton, prefix every command with `carton exec --` so that Perl picks up the `local/` library paths:

```sh
carton exec -- perl -e 'use Typist; say "ok"'
carton exec -- perl bin/typist-check --help
carton exec -- perl example/01_foundations.pl
```

## Available Commands via mise

The project ships a `mise.toml` with task definitions for common workflows. These all use `carton exec` internally, so you do not need to prefix commands yourself.

| Command | Description |
|---------|-------------|
| `mise run deps` | Install dependencies via Carton |
| `mise run check` | Run `typist-check` static analysis on `lib/` |
| `mise run test` | Run all test suites in parallel |
| `mise run test:core` | Core type system tests (`t/`) |
| `mise run test:static` | Static analysis tests (`t/static/`) |
| `mise run test:lsp` | LSP server tests (`t/lsp/`) |
| `mise run test:critic` | Perl::Critic policy tests (`t/critic/`) |
| `mise run test:e2e` | LSP end-to-end smoke test |
| `mise run example` | Run all example programs |

## Next Steps

With everything installed, proceed to [First Program](first-program.md) to write your first typed Perl program.
