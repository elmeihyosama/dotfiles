-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Borders on every floating window (LSP hover, pickers, which-key), driven
-- by design.border so it stays in sync with the active theme's chrome.
if vim.fn.has("nvim-0.11") == 1 then
  vim.o.winborder = require("config.design").border
end
