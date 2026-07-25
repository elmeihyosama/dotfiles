local d = require("config.design")

local function block(color)
  return {
    a = { bg = color, fg = d.bg, gui = "bold" },
    b = { bg = d.surface, fg = d.text },
    c = { bg = d.surface, fg = d.subtle },
  }
end

local theme = {
  normal = block(d.accent),
  insert = block(d.warn),
  visual = block(d.link),
  replace = block(d.err),
  command = block(d.accent2),
  inactive = block(d.overlay),
}

local muted = { fg = d.muted, bg = d.surface }
local subtle = { fg = d.subtle, bg = d.surface }

return {
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      opts.options = vim.tbl_deep_extend("force", opts.options or {}, {
        theme = theme,
        component_separators = "",
        section_separators = "",
        globalstatus = true,
      })
      -- Right side: filetype, encoding, position, scroll % — all quiet.
      opts.sections = opts.sections or {}
      opts.sections.lualine_x = {
        { "filetype", color = muted },
        { "encoding", color = muted },
      }
      opts.sections.lualine_y = { { "location", color = subtle } }
      opts.sections.lualine_z = { { "progress", color = subtle } }
      return opts
    end,
  },
  {
    "folke/snacks.nvim",
    opts = {
      dashboard = {
        preset = {
          -- Moon mark, quoted per line so art spacing stays out of code indentation.
          header = table.concat({
            "    ▄▄▄▄▄",
            "  ▄█▀▀░░░▀▀█▄",
            " ██░░░░░░░░░██",
            " ██░░░●░░░░░██",
            "  ▀█▄░░░░▄█▀",
            "    ▀▀▀▀▀",
          }, "\n"),
        },
      },
    },
  },
}
