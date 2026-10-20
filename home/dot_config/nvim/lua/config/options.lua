-- Loaded before lazy.nvim. LazyVim's defaults: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua

-- Borders on every float, from design.border (follows the theme).
if vim.fn.has("nvim-0.11") == 1 then
  vim.o.winborder = require("config.design").border
end

-- Over SSH, clipboard via OSC 52 (ghostty forwards it). Copy-only: paste is a
-- no-op so nvim never blocks on an OSC 52 read (ghostty prompts on those).
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
