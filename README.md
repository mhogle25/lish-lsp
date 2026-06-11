# lish-lsp

Language Server Protocol implementation for [lish](https://github.com/mhogle25/lish-zig).

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

Early. Tracking against the B2 milestone in lish-zig's roadmap:

- [ ] B2.1 — JSON-RPC framing
- [ ] B2.2 — initialize / shutdown handshake
- [ ] B2.3 — Document sync
- [ ] B2.4 — Diagnostics from parser errors
- [ ] B2.5 — Semantic tokens
- [ ] B2.6 — Editor configs (Neovim + VS Code)
