-- Highlight chezmoi `*.tmpl` files as their base filetype (starship.toml.tmpl → toml).
vim.filetype.add({
  pattern = {
    [".*%.tmpl"] = function(path)
      local base = (path:gsub("%.tmpl$", ""))
      return vim.filetype.match({ filename = base }) or "gotmpl"
    end,
  },
})

return {}
