-- Live theme reload, called over RPC by `theme`/`glass`/`wallpaper` after
-- chezmoi re-renders the theme modules.
local M = {}

local function fresh(mod)
  package.loaded[mod] = nil
  return require(mod)
end

function M.reload()
  fresh("config.design")
  -- Same colorscheme step LazyVim runs from plugins/colorscheme.lua.
  for _, spec in ipairs(fresh("plugins.colorscheme")) do
    local cs = type(spec.opts) == "table" and spec.opts.colorscheme
    if type(cs) == "function" then
      cs()
    elseif type(cs) == "string" then
      vim.cmd.colorscheme(cs)
    end
  end
  -- Lualine's theme comes from config.design (plugins/ui.lua); only if loaded.
  local lualine = package.loaded.lualine
  if lualine then
    for _, spec in ipairs(fresh("plugins.ui")) do
      if spec[1] == "nvim-lualine/lualine.nvim" and type(spec.opts) == "function" then
        lualine.setup(spec.opts(spec, lualine.get_config()))
      end
    end
  end
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = vim.g.colors_name or "", modeline = false })
  return vim.g.colors_name
end

return M
