# lish-lsp for Neovim

Drop-in configuration for Neovim 0.10+ using the built-in `vim.lsp.start` API.
No external plugins required.

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
