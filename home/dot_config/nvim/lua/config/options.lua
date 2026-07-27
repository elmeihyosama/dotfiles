-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Borders on every floating window (LSP hover, pickers, which-key), driven
-- by design.border so it stays in sync with the active theme's chrome.
if vim.fn.has("nvim-0.11") == 1 then
  vim.o.winborder = require("config.design").border
end

-- Over SSH there is no local clipboard tool, so route nvim's clipboard through
-- OSC 52 (ghostty forwards it to the local Mac). Local nvim keeps LazyVim's
-- native provider. Copy-only: paste is a no-op so nvim never blocks on an
-- OSC 52 read (ghostty prompts on those).
if (vim.env.SSH_TTY or vim.env.SSH_CONNECTION) and vim.fn.has("nvim-0.10") == 1 then
  local osc52 = require("vim.ui.clipboard.osc52")
  vim.g.clipboard = {
    name = "osc52",
    copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
    paste = {
      ["+"] = function()
        return { {}, "" }
      end,
      ["*"] = function()
        return { {}, "" }
      end,
    },
  }
end
