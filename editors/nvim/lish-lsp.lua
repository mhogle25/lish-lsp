-- lish-lsp client configuration for Neovim 0.10+.
-- Drop this file into your config (e.g. ~/.config/nvim/lua/lish-lsp.lua) and
-- `require('lish-lsp')` from init.lua.

vim.filetype.add({
  extension = {
    lish = 'lish',
    lishmacro = 'lish',
  },
})

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'lish',
  callback = function(args)
    vim.lsp.start({
      name = 'lish-lsp',
      cmd = { 'lish-lsp' },
      root_dir = vim.fs.root(args.buf, { '.git' }) or vim.fn.getcwd(),
    })
  end,
})
