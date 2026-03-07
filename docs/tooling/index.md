# Tooling

Typist provides several tools beyond the type system itself: a CLI static checker, an LSP server for editor integration, Perl::Critic policies for code review, and diagnostic tools for debugging the inference engine.

## Tools

| Page | Description |
|------|-------------|
| [typist-check](typist-check.md) | CLI static analysis tool for checking `.pm` files |
| [LSP Server](lsp.md) | Language server with diagnostics, hover, completion, and more |
| [Perl::Critic Policies](critic.md) | Annotation style, effect completeness, and match exhaustiveness checks |
| [Debug Tools](debug-tools.md) | `typist-infer-dump`, `typist-ppi-dump`, and `typist-registry-dump` |

## Quick Reference

```sh
typist-check                          # Check lib/ for type errors
typist-check lib/MyApp/Order.pm       # Check specific file
typist-lsp                            # Start LSP server (used by editors)
typist-infer-dump lib/MyApp/Order.pm  # Dump inferred variable types
typist-ppi-dump lib/MyApp/Order.pm    # Dump PPI AST
typist-registry-dump --root lib/      # Dump workspace registry
```
