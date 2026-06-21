# lish-lsp

Language Server Protocol implementation for [lish](https://github.com/mhogle25/lish).

Provides diagnostics, semantic tokens, and (eventually) hover, completion, and
go-to-definition for `.lish` and `.lishmacro` files.

Speaks LSP over stdio. Most editors expect this; spawn `lish-lsp` and connect
via standard input/output.

## Building

```sh
zig build
```

The binary lands at `zig-out/bin/lish-lsp`.

## Status

Early. Tracking against the B2 milestone in lish's roadmap:

- [x] B2.1: JSON-RPC framing
- [x] B2.2: initialize / shutdown handshake
- [x] B2.3: Document sync
- [x] B2.4: Diagnostics from parser errors
- [x] B2.5: Semantic tokens
- [x] B2.6: Editor configs (Neovim + VS Code)

## Editors

- **Neovim:** see [`editors/nvim/`](editors/nvim/). Drop-in Lua snippet for Neovim 0.10+.
- **VS Code:** see [`editors/vscode/`](editors/vscode/). Build with `npm install && npm run compile`, then `F5` to launch a dev host.
