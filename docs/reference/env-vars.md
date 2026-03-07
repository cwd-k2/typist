# Environment Variables

All environment variables recognized by Typist, its LSP server, and the `typist-check` CLI.

## Summary

| Variable | Values | Default | Description |
|----------|--------|---------|-------------|
| `TYPIST_RUNTIME` | `1` | off | Enable runtime type enforcement |
| `TYPIST_STATIC` | `1` | off | Enable CHECK-phase static analysis |
| `TYPIST_CHECK_QUIET` | `1` | off | Silence CHECK-phase static diagnostics |
| `TYPIST_LSP_LOG` | `off`, `error`, `warn`, `info`, `debug`, `trace` | `info` | LSP server log level |
| `TYPIST_LSP_TRACE` | file path | (none) | Record LSP messages to JSONL file |
| `NO_COLOR` | (any value) | (none) | Disable colored output in `typist-check` |

## Detailed Reference

### `TYPIST_RUNTIME`

Enables runtime type enforcement. Equivalent to `use Typist -runtime;` in source code.

When set to `1`:

- Constructor type validation is enabled (subtype checks via `contains`, `infer_value`, bounds, typeclass constraints).
- `Tie::Scalar` variable monitoring is active for annotated variables.
- Heavy modules (`Typist::Inference`, `Typist::Subtype`) are loaded at import time.

When unset or `0` (the default):

- Only structural enforcement is active at runtime (unknown fields, required fields, arity checks in constructors).
- No `Tie::Scalar` monitoring.
- Static analysis is still opt-in via `-static` or `TYPIST_STATIC=1`.

```bash
# Enable via environment
TYPIST_RUNTIME=1 perl my_app.pl

# Equivalent in source code
use Typist -runtime;
```

| Mechanism | Default (`use Typist`) | Runtime (`-runtime` or `TYPIST_RUNTIME=1`) |
|-----------|------------------------|--------------------------------------------|
| Static analysis (CHECK) | OFF | OFF |
| Structural checks (arity, fields) | ON | ON |
| Effect dispatch | ON | ON |
| Typeclass dispatch | ON | ON |
| Constructor type validation | OFF | ON |
| `Tie::Scalar` variable monitoring | OFF | ON |

### `TYPIST_STATIC`

Enables CHECK-phase static analysis. Equivalent to `use Typist -static;` in source code.

When set to `1`:

- Typist registers a CHECK hook during compile time.
- Structural validation and whole-file static analysis run at CHECK time.
- Diagnostics are printed to STDERR unless `TYPIST_CHECK_QUIET=1` is also set.

When unset or `0` (the default):

- `use Typist;` only installs runtime helpers and prelude definitions.
- No CHECK-phase static analysis runs.
- Use `typist-check` or the LSP for explicit static analysis.

```bash
# Enable compile-time static analysis
TYPIST_STATIC=1 perl my_app.pl

# Equivalent in source code
use Typist -static;
```

### `TYPIST_CHECK_QUIET`

Suppresses the CHECK-phase static analysis output.

When set to `1`, Typist still registers the static CHECK hook when enabled, but skips the full `_check_analyze()` pass and suppresses diagnostic STDERR output from that phase.

This is useful when the LSP server is running, since the LSP provides the same diagnostics inline in the editor. Without this setting, you would see duplicate diagnostics: once from the CHECK phase on STDERR, and once from the LSP in the editor.

```bash
# Suppress CHECK output when LSP is active
export TYPIST_CHECK_QUIET=1
TYPIST_STATIC=1 perl my_app.pl    # No STDERR diagnostics from CHECK phase
```

This does **not** affect:

- The `typist-check` CLI (which runs its own analysis pipeline).
- The LSP server's diagnostics.
- Runtime behavior.

### `TYPIST_LSP_LOG`

Sets the log level for the Typist LSP server. Logs are written to STDERR.

| Level | Value | Description |
|-------|-------|-------------|
| `off` | 0 | No logging |
| `error` | 1 | Errors only |
| `warn` | 2 | Warnings and above |
| `info` | 3 | Informational messages and above (default) |
| `debug` | 4 | Debug messages and above |
| `trace` | 5 | All messages, including raw protocol data |

```bash
# Debug LSP server issues
TYPIST_LSP_LOG=debug typist-lsp

# Silence all logs
TYPIST_LSP_LOG=off typist-lsp

# Maximum verbosity
TYPIST_LSP_LOG=trace typist-lsp
```

Log output format:

```
[HH:MM:SS] [level] message text
```

### `TYPIST_LSP_TRACE`

Records all LSP JSON-RPC messages to a file in JSONL (JSON Lines) format. Each line is a JSON object with a timestamp and the full message content.

Set this to a file path. The file is opened in append mode.

```bash
# Record LSP traffic for debugging
TYPIST_LSP_TRACE=/tmp/typist-trace.jsonl typist-lsp

# Then inspect the trace
cat /tmp/typist-trace.jsonl | jq .
```

This is useful for debugging LSP client-server communication issues. The trace includes both incoming requests/notifications and outgoing responses/notifications.

### `NO_COLOR`

When set to any value, disables ANSI color codes in `typist-check` output. Follows the [no-color.org](https://no-color.org/) convention.

Color is also disabled automatically when:

- `--no-color` is passed to `typist-check`.
- Standard output is not a TTY (e.g., piped to a file or another program).

```bash
# Disable color via environment
NO_COLOR=1 typist-check

# Or via CLI flag
typist-check --no-color

# Piping also disables color automatically
typist-check | less
```

The debug tools (`typist-infer-dump`, `typist-ppi-dump`, `typist-registry-dump`) also respect `NO_COLOR`.

## Usage Patterns

### Development with LSP

When using the LSP server in your editor, suppress CHECK-phase output to avoid duplicates:

```bash
export TYPIST_CHECK_QUIET=1
```

### CI / Continuous Integration

Use `typist-check` with no-color for machine-readable output:

```bash
NO_COLOR=1 typist-check --root lib/
# Exit code: 0 = clean, 1 = errors, 2 = warnings only
```

### Debugging Type Inference

Enable runtime enforcement and verbose LSP logging:

```bash
TYPIST_RUNTIME=1 perl my_app.pl          # Runtime checks
TYPIST_LSP_LOG=debug typist-lsp          # Verbose LSP
TYPIST_LSP_TRACE=/tmp/trace.jsonl typist-lsp  # Full message trace
```

### Production

In production, use plain `use Typist;` by default. No static analysis runs unless you opt into it, so direct program execution stays free of compile-time analyzer overhead:

```typist
use Typist;  # Runtime helpers only, no static CHECK pass
```
