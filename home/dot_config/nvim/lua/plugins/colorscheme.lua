return {
  -- Rosé Pine (matches the terminal's Rosé Pine Moon)
  {
    "rose-pine/neovim",
    name = "rose-pine",
    lazy = false,
    priority = 1000,
    opts = {
      variant = "moon",
      dark_variant = "moon",
      styles = { italic = false },
    },
  },
  -- Make LazyVim use it
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "rose-pine-moon",
    },
  },
}
