-- MINIMAL EXAMPLE: connects the lish-lsp language server, nothing more. The full
-- editing experience (tree-sitter highlighting/indent, structural indent, a run
-- command) is editor glue + grammar config that lives in your own dotfiles and in
-- tree-sitter-lish, not here. This file is the "just talk to the LSP" starting point.
--
-- lish-lsp client configuration for Neovim 0.11+.
--
-- Drop this file into your config (e.g. ~/.config/nvim/lua/lish-lsp.lua) and
-- `require('lish-lsp')` from init.lua. Uses only core APIs, so it works with any
-- plugin manager (or none).

-- 1. Teach Neovim the file extensions. Both map to one `lish` filetype; the
--    server tells `.lish` (expressions) from `.lishmacro` (macro modules) by the
--    document URI, not the filetype.
vim.filetype.add({
  extension = {
    lish = 'lish',
    lishmacro = 'lish',
  },
})

-- 2. Register and enable the server. `vim.lsp.config` defines it and
--    `vim.lsp.enable` starts it automatically for matching filetypes.
vim.lsp.config('lish-lsp', {
  -- On PATH after installing; or use an absolute path to the built binary, e.g.
  -- { '/path/to/lish-lsp/zig-out/bin/lish-lsp' }.
  cmd = { 'lish-lsp' },
  filetypes = { 'lish' },
  -- Workspace root: where the server scans for `.lishmacro` files (go-to-def,
  -- completion of workspace macros). `.git` is a sensible default marker.
  root_markers = { '.git' },
})

vim.lsp.enable('lish-lsp')

-- The server provides hover, go-to-definition, diagnostics, semantic-token
-- highlighting, and completion out of the box. Wiring is up to you, for example:
--
--   * Keymaps on attach (`vim.lsp.buf.hover`, `vim.lsp.buf.definition`, ...) via
--     an `LspAttach` autocmd.
--   * Completion: native `vim.lsp.completion.enable(...)` (0.11+), or a plugin
--     such as nvim-cmp / blink.cmp with its LSP source. The server advertises no
--     completion trigger characters on purpose (a lisp opens every call with
--     `(`); completion fires on the operator name's first letter instead.
--   * If you use an autopairs plugin with a "insert () after functions"
--     completion hook, disable it for the `lish` filetype — lish calls are
--     prefix `(op ...)`, not `op()`.
