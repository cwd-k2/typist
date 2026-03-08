# Editor Setup

Typist ships with `typist-lsp`, a Language Server Protocol server that brings type-aware editor features to any LSP-compatible editor. This page covers configuration for Neovim and VS Code, the two editors with tested setups.

## What the LSP Server Provides

| Feature | Description |
|---------|-------------|
| Diagnostics | Type, arity, effect, and protocol errors published on file open and save |
| Hover | Type signatures and documentation displayed on hover |
| Completion | Type-aware suggestions: struct fields, effect operations, constructors, type names |
| Go to Definition | Jump to type and function definitions, both same-file and cross-file |
| Find References | Locate all usages of a type, function, or variable across the workspace |
| Rename | Rename symbols consistently across the workspace |
| Signature Help | Parameter hints while typing function calls (triggered by `(` and `,`) |
| Inlay Hints | Inferred types for unannotated variables, effect labels, and protocol state transitions |
| Code Actions | Quick-fix suggestions: effect annotation insertion, type correction edits |
| Semantic Tokens | Syntax highlighting for Typist type names, keywords, and annotation structure |
| Document Symbols | Outline view of types, functions, and declarations in the current file |

### Diagnostic timing

Diagnostics are published when a file is opened (`didOpen`) and when it is saved (`didSave`). They are not re-computed on every keystroke. This keeps the server responsive while still providing feedback at the natural save-and-check rhythm.

## Neovim

### Using nvim-lspconfig

Add a custom server definition for Typist in your Neovim configuration:

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

This tells Neovim to start `typist-lsp` for Perl files, using the nearest `lib/` or `.git/` ancestor as the workspace root.

If `typist-lsp` is not on your `$PATH` (for example, when using Carton), specify the full path in the `cmd` table:

```lua
cmd = { 'carton', 'exec', '--', 'perl', 'bin/typist-lsp' },
```

### Manual setup (without nvim-lspconfig)

If you prefer to use `vim.lsp.start` directly:

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'perl',
  callback = function()
    vim.lsp.start {
      name = 'typist',
      cmd  = { 'typist-lsp' },
      root_dir = vim.fs.dirname(
        vim.fs.find({ 'lib', '.git' }, { upward = true })[1]
      ),
    }
  end,
})
```

## VS Code

A dedicated VS Code extension is provided in the `editors/vscode/` directory of the Typist repository.

### Build and install

```sh
cd editors/vscode
npm install
npm run build
npx @vscode/vsce package
code --install-extension typist-0.0.1.vsix
```

Or, using the mise task aliases:

```sh
mise run vscode:deps
mise run vscode:install
```

### Server resolution

The extension resolves the `typist-lsp` binary in the following order:

1. The path specified in the `typist.server.path` setting (if non-empty).
2. `local/bin/typist-lsp` relative to the workspace root.
3. `typist-lsp` on `$PATH`.

To override, open VS Code settings and set:

```json
{
  "typist.server.path": "/path/to/your/typist-lsp"
}
```

## Suppressing Redundant CHECK Output

When the LSP server is running, it provides the same diagnostics that opt-in CHECK analysis would emit to STDERR. If you also enable CHECK analysis (`TYPIST_CHECK=1` or `use Typist -check;`), set `TYPIST_CHECK_QUIET` to avoid duplicate terminal warnings:

```sh
export TYPIST_CHECK=1
export TYPIST_CHECK_QUIET=1
```

This suppresses CHECK-phase STDERR output while leaving the LSP diagnostics active. Add this only if you explicitly enable CHECK analysis and use the LSP server as your primary feedback channel.

## LSP Environment Variables

The server recognizes several environment variables for debugging and logging:

| Variable | Description |
|----------|-------------|
| `TYPIST_CHECK=1` | Enable CHECK-phase static diagnostics in direct `perl` runs |
| `TYPIST_CHECK_QUIET=1` | Suppress CHECK-phase STDERR diagnostics when static analysis is enabled |
| `TYPIST_LSP_LOG=LEVEL` | Set log level: `off`, `error`, `warn`, `info` (default), `debug`, `trace`. Logs go to STDERR |
| `TYPIST_LSP_TRACE=/path/to.jsonl` | Record all LSP messages with timestamps to a JSONL file |

## Other Editors

Any editor with LSP support can use `typist-lsp`. The server communicates over stdin/stdout using JSON-RPC with Content-Length framing -- the standard LSP transport. Configure your editor to launch `typist-lsp` (or `carton exec -- perl bin/typist-lsp`) as the language server for Perl files, with the workspace root set to the directory containing `lib/`.

## Next Steps

With your editor configured, you have real-time diagnostics, hover information, and completion as you write. Explore the rest of the documentation:

- **[Guide](../guide/index.md)** -- Type annotations, type system, effects, and more
- **[LSP Coverage](../internal/lsp-coverage.md)** -- Full feature matrix, diagnostic kinds, and completion contexts
