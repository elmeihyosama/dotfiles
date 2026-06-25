-- Highlight chezmoi `*.tmpl` files as their base filetype (e.g. starship.toml.tmpl →
-- toml). Without this, nvim sees only `.tmpl` and applies no syntax highlighting.
vim.filetype.add({
  pattern = {
    [".*%.tmpl"] = function(path)
      local base = (path:gsub("%.tmpl$", ""))
      return vim.filetype.match({ filename = base }) or "gotmpl"
    end,
  },
})

return {}
