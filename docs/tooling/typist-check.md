# typist-check

`typist-check` is the CLI static analysis tool for Typist. It runs the same analysis engine as the LSP server and reports type errors, effect mismatches, arity violations, and other diagnostics to the terminal.

---

## Usage

```sh
typist-check                          # Scan lib/ for .pm files
typist-check lib/MyApp/Order.pm       # Check specific file(s)
typist-check --root src/              # Custom workspace root
typist-check --no-color               # Disable colored output
typist-check --verbose                # Show clean files too
typist-check --help                   # Print usage and exit
```

When no files are specified, `typist-check` scans `lib/` (or the current directory if `lib/` does not exist) for `.pm` files and checks all of them.

---

## Options

| Option | Description |
|--------|-------------|
| `--root DIR` | Set the workspace root directory for cross-file type resolution. Defaults to `lib/` if it exists, otherwise the current directory. All `.pm` files under this root are indexed for cross-file resolution. |
| `--no-color` | Disable ANSI color codes in output. Also disabled automatically when `NO_COLOR` is set or stdout is not a terminal. |
| `-v`, `--verbose` | Show all checked files in output, including those with no diagnostics. |
| `-h`, `--help` | Print usage information and exit. |

---

## Output Format

```
lib/MyApp/Order.pm
  42:5    error    expected Int, got Str in argument 1  [TypeMismatch]
  58:1    error    wrong number of arguments             [ArityMismatch]

lib/MyApp/Payment.pm
  17:1    warning  undeclared type variable 'T'          [UndeclaredTypeVar]

2 error(s), 1 warning(s) in 2 file(s) (4 files checked)
```

Each diagnostic line has the format:

```
  line:col  severity  message  [DiagnosticKind]
```

- **File path** is printed in bold (when color is enabled).
- **Severity** is `error` (red) for severity 1-2, `warning` (yellow) for severity 3-4, and `hint` (cyan) for severity 5+.
- **Hints** (severity 5+) are only shown in `--verbose` mode.
- A blank line separates files.
- The summary line shows total errors, warnings, files with diagnostics, and total files checked.

When all files are clean:

```
All clean. (4 file(s) checked)
```

---

## Exit Codes

| Code | Meaning |
|:----:|---------|
| `0` | All clean -- no diagnostics found |
| `1` | Errors found (severity 1-2: TypeMismatch, ArityMismatch, ResolveError, etc.) |
| `2` | Warnings only (severity 3-4: UndeclaredTypeVar, UnknownType, ImportHint, etc.) |

---

## Diagnostic Kinds

All diagnostic kinds produced by the static analyzer:

| Kind | Severity | Description |
|------|:--------:|-------------|
| CycleError | 1 | Circular type alias definition |
| TypeError | 2 | Structural type error in definition |
| TypeMismatch | 2 | Expected type does not match actual type |
| ArityMismatch | 2 | Wrong number of arguments to a function |
| ResolveError | 2 | Cannot resolve a type name or function |
| EffectMismatch | 2 | Function uses effects not declared in its annotation |
| ProtocolMismatch | 2 | Effect protocol state transition violation |
| UndeclaredTypeVar | 3 | Type variable used but not declared in generics |
| UndeclaredRowVar | 3 | Row variable used but not declared |
| UnknownEffect | 3 | Effect name not found in registry |
| UnknownTypeClass | 2 | Typeclass name not found in registry |
| UnknownType | 4 | Type name not found in registry |
| InvalidBound | 3 | Invalid bound expression on generic parameter |
| KindError | 3 | Kind mismatch (e.g., applying type arguments to a non-parameterized type) |
| ImportHint | 4 | Type used in `:sig()` but defining package not imported |

---

## Cross-File Resolution

`typist-check` builds a cross-file workspace registry before analyzing individual files. This is the same mechanism used by the LSP server:

1. All `.pm` files under `--root` are scanned.
2. Type definitions, function signatures, effects, typeclasses, structs, and instances are extracted and registered.
3. Each file is then analyzed with full cross-file visibility.

This means `typist-check` catches errors that involve types defined in other files, just as the LSP does.

---

## CI Integration

### GitHub Actions

```yaml
- name: Install dependencies
  run: carton install

- name: Type check
  run: carton exec -- typist-check --no-color
```

### GitLab CI

```yaml
type_check:
  script:
    - carton install
    - carton exec -- typist-check --no-color
```

### General CI

Color is auto-disabled when stdout is not a TTY (which is the case in most CI environments). The `--no-color` flag is redundant in these cases but makes the intent explicit. The `NO_COLOR` environment variable (per [no-color.org](https://no-color.org)) also disables color.

Use the exit code to fail the build:
- Exit `1` (errors) should fail the build.
- Exit `2` (warnings) can be treated as a soft failure or ignored, depending on your project's policy.

```sh
typist-check --no-color
status=$?
if [ $status -eq 1 ]; then
    echo "Type errors found"
    exit 1
elif [ $status -eq 2 ]; then
    echo "Warnings found (non-fatal)"
fi
```

---

## Environment Variables

| Variable | Effect |
|----------|--------|
| `NO_COLOR` | When set, disables colored output |
| `TYPIST_CHECK` | Set to `1` to enable CHECK-phase diagnostics in direct `perl` runs. `typist-check` itself does not require this. |
| `TYPIST_CHECK_QUIET` | Set to `1` to suppress CHECK-phase output from modules being analyzed when static mode is enabled separately (recommended when diagnostics come from `typist-check` itself) |

---

## Relationship to the LSP

`typist-check` and `typist-lsp` share the same analysis engine (`Typist::Static::Analyzer`) and cross-file workspace (`Typist::LSP::Workspace`). They produce identical diagnostics. Use `typist-check` for CI and batch checking; use `typist-lsp` for interactive editing.
