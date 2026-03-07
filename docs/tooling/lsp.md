# LSP Server

`typist-lsp` is a Language Server Protocol server that provides type-aware editor features for Perl files using the Typist type system. It communicates over stdin/stdout using JSON-RPC with Content-Length framing.

---

## Starting the Server

```sh
typist-lsp
```

The server is not invoked directly in normal usage -- your editor starts it automatically based on its LSP configuration. See [Editor Setup](../getting-started/editor-setup.md) for Neovim, VS Code, and other editor configurations.

---

## Features

### Diagnostics

Real-time type errors, effect mismatches, arity violations, protocol violations, and other issues reported as you code. Diagnostics are published on `didOpen` and `didSave` events.

Diagnostic kinds include:

| Kind | Description |
|------|-------------|
| TypeMismatch | Expected type does not match actual type |
| ArityMismatch | Wrong number of arguments |
| EffectMismatch | Undeclared effects in function body |
| ProtocolMismatch | Effect protocol state transition violation |
| CycleError | Circular type alias |
| TypeError | Structural type error |
| ResolveError | Unresolvable type or function name |
| UndeclaredTypeVar | Type variable not in scope |
| UnknownType | Type name not found in registry |
| ImportHint | Type used but defining package not imported |

### Hover

Hover over any symbol to see its type information:

- **Functions**: full signature including generics, parameters, return type, and effects
- **Parameters**: name, type, and owning function
- **Variables**: declared or inferred type
- **Type definitions**: `typedef`, `newtype`, `datatype`, `struct` definitions with fields and variants
- **Effects**: operation table with signatures and protocol transitions
- **Typeclasses**: name, type parameter, and method list
- **Struct fields**: field name, type, required/optional status (also for constructor keys: `Point(x => 1)` -- hover on `x`)
- **Built-in types**: description and position in the type hierarchy
- **Keywords**: `match` shows the matched expression's type and result; `handle` shows handled effects

Cross-file hover is supported: hovering over a type or function defined in another file shows its definition via the workspace registry.

Hover is suppressed in comments, Pod sections, and string literals to prevent false matches where a word in a comment or string happens to share a name with a registered type or function. Strings inside Typist declarations (`typedef`, `struct`, `effect`, etc.) are exempt -- type names in these strings still show hover information.

### Completion

Context-aware completion in two areas:

**Inside `:sig()` annotations:**

| Context | Candidates |
|---------|------------|
| Type expression | Primitive types, parameterized types (`ArrayRef[...]`, `Maybe[...]`), `forall` snippet, workspace typedefs |
| Generic parameter | Document-level generics, standard vars (`T`, `U`, `V`, `K`) |
| Effect row (`![...]`) | Workspace effect names |
| Constraint (`<T: ...>`) | Workspace typeclass names |

**In code body:**

| Context | Trigger | Candidates |
|---------|---------|------------|
| Struct field access | `$var->{` or `$var->` | Struct fields with type details |
| Same-package method | `$self->` | Methods with signature details |
| Cross-package method | `$obj->` | Struct fields and `with` from inferred type |
| Effect operation | `Effect::` | Effect operations with signatures |
| Match arm | `match $val,` | Datatype variant names (with snippets, excludes already-used arms) |
| Constructor | Uppercase word | Constructor names from workspace |

### Go to Definition

Jump to the definition of types, functions, constructors, struct fields, and effect operations. Works both within the same file and across files via the workspace.

| Target | Same-file | Cross-file |
|--------|:---------:|:----------:|
| Type definitions (typedef, newtype, datatype, struct, effect, typeclass) | Yes | Yes |
| Functions | Yes | Yes |
| Datatype constructors | -- | Yes (jumps to owning datatype) |
| Struct fields | Yes | Yes |
| Effect operations | Yes | Yes |
| Local variables | Partial | -- |

### References and Rename

Find all references to a symbol across the workspace and rename them. References use word-boundary matching; variables have scope-aware resolution that respects lexical scope.

- **Same-file**: word boundary regex search
- **Cross-file**: workspace-wide search across all indexed files
- **Rename**: word boundary replace across all files
- **Scope-aware**: variable references are filtered by lexical scope

### Signature Help

Displays parameter information for function calls, method calls, and constructor calls. Supports multi-line calls with a 20-line lookback window.

| Call context | Mechanism |
|-------------|-----------|
| Function call `fn(` | Signature from local symbols or registry |
| Cross-package function | Registry `search_function_by_name` fallback |
| Method call `$obj->method(` | Var type resolution to struct method signature |
| Constructor call `Name(field =>` | Struct lookup with field parameters |
| Multi-line call | 20-line lookback to find the opening call |

### Inlay Hints

Inline type annotations for unannotated code elements:

| Hint | Description |
|------|-------------|
| Variable type | Inferred type for unannotated `my $var = expr` |
| Loop variable | Element type for `for my $var (@list)` |
| Callback parameter | Parameter type for anonymous sub callbacks |
| Protocol state | State transition labels at effect operation call sites |
| Function effects | Inferred effect row for unannotated functions |
| Function return type | Inferred return type for unannotated functions |

### Code Actions

Quick fixes for specific diagnostics:

| Diagnostic | Action |
|-----------|--------|
| EffectMismatch | Auto-edit: insert or append `![Label]` to the function's `:sig()` annotation |
| TypeMismatch | Auto-edit: change the type in the `:sig()` annotation to match the actual type |

### Semantic Tokens

Enhanced syntax highlighting for Typist constructs:

| Token | Token type | Where |
|-------|-----------|-------|
| Type names (typedef, newtype, datatype, struct) | `type` | Definitions and `:sig()` usage |
| Generic parameters | `typeParameter` | Definitions and `:sig()` usage |
| Functions | `function` | Definitions |
| Annotated variables | `variable` + `declaration` | Definitions |
| Keywords (typedef, newtype, struct, etc.) | `keyword` | Definitions |
| Effect names | `enum` | Definitions |
| Typeclass names | `class` | Definitions |
| Datatype variants | `enumMember` | Definitions and code body usage |
| Struct field names | `property` + `readonly` | Definitions |
| Operators in `:sig()` | `operator` | `->`, `!` in annotations |
| Constructor usage | `enumMember` / `function` | Code body |
| Effect operation usage | `enum` + `function` | Code body |

### Document Symbols

Provides an outline of type definitions, functions, and other named symbols in the current file.

---

## Diagnostics Timing

Diagnostics are published on `didOpen` (when a file is first opened) and `didSave` (when a file is saved). They are not published on every keystroke (`didChange`).

Hover, completion, inlay hints, and other interactive features use lazy analysis and are always current -- they re-analyze the document on each request.

This design balances responsiveness with performance: full PPI parse plus type checking on every keystroke would be prohibitively expensive for large files.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TYPIST_LSP_LOG` | `info` | Log level: `off`, `error`, `warn`, `info`, `debug`, `trace`. Logs go to stderr. |
| `TYPIST_LSP_TRACE` | (none) | Path to a JSONL file for recording all LSP messages with timestamps. Useful for debugging editor integration. |
| `TYPIST_STATIC` | (unset) | Set to `1` to enable CHECK-phase output in direct `perl` runs. Usually unnecessary when using the LSP. |
| `TYPIST_CHECK_QUIET` | (unset) | Set to `1` to suppress CHECK-phase output when static mode is enabled. Recommended when using the LSP, as it provides the same diagnostics inline. |

### Debugging

To diagnose LSP issues, increase the log level and optionally enable message tracing:

```sh
TYPIST_LSP_LOG=debug typist-lsp
```

```sh
TYPIST_LSP_TRACE=/tmp/typist-lsp.jsonl typist-lsp
```

The trace file records every JSON-RPC message sent and received, which is useful for diagnosing editor communication issues.

---

## Editor Configuration

### Neovim (nvim-lspconfig)

```lua
local configs = require('lspconfig.configs')

configs.typist = {
  default_config = {
    cmd = { 'typist-lsp' },
    filetypes = { 'perl' },
    root_dir = function(fname)
      return vim.fs.dirname(
        vim.fs.find({ 'lib', '.git' }, { upward = true, path = fname })[1]
      )
    end,
  },
}

require('lspconfig').typist.setup {}
```

### VS Code

A dedicated extension is provided at `editors/vscode/`:

```sh
cd editors/vscode
npm install && npm run build
npx vsce package
code --install-extension typist-0.0.1.vsix
```

The extension looks for `local/bin/typist-lsp` in the workspace root, then falls back to `typist-lsp` on `$PATH`. Override with the `typist.server.path` setting.

### Other Editors

Any editor with LSP support can use `typist-lsp`. Configure it as a language server for Perl files with `typist-lsp` as the command. The server uses stdin/stdout for communication with Content-Length framing.

---

## Workspace

The LSP workspace provides cross-file type resolution. When a project is opened, the server:

1. Scans all `.pm` files under the workspace root.
2. Extracts and registers types, functions, effects, typeclasses, structs, and instances.
3. Builds a shared registry for cross-file resolution.
4. Updates incrementally when files are saved.

This enables cross-file hover, go-to-definition, completion, diagnostics, references, and rename.
