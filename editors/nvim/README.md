# lish-lsp for Neovim

**Minimal example — connects the language server, nothing more.** The full editing
experience (tree-sitter highlighting/indent, structural indent, a run command) is
editor glue + grammar config that lives in your own dotfiles and in
`tree-sitter-lish`, not here. This is the "just talk to the LSP" starting point.

Drop-in configuration for Neovim 0.11+ using the built-in `vim.lsp.config` /
`vim.lsp.enable` API. No external plugins required.

## Install

1. Build `lish-lsp` and put the binary on your `PATH`:
   ```sh
   cd /path/to/lish-lsp && zig build -Doptimize=ReleaseSafe
   cp zig-out/bin/lish-lsp ~/.local/bin/
   ```
2. Source `lish-lsp.lua` from your Neovim config. For example, drop it next to
   your `init.lua` and add:
   ```lua
   require('lish-lsp')
   ```
   Or paste its contents directly into your config.

## What it does

- Registers `.lish` and `.lishmacro` files as filetype `lish`.
- Auto-starts `lish-lsp` for every buffer of that filetype.
- Picks the project root by walking upward from the file looking for `.git`.

## Verify

Open a `.lish` file, then:

```
:LspInfo
```

You should see `lish-lsp` listed as attached.
