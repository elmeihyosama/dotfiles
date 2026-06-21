return {
  -- Treesitter parsers for the always-on filetypes
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, {
        "lua",
        "bash",
        "yaml",
        "json",
        "toml",
        "markdown",
        "markdown_inline",
      })
    end,
  },
  -- LSP servers: Lua + Bash (clangd/pyright come from the extras)
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        lua_ls = {},
        bashls = {},
      },
    },
  },
  -- Formatters/linters via Mason (shfmt for shell; actionlint for GH Actions)
  {
    "mason-org/mason.nvim",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      vim.list_extend(opts.ensure_installed, { "shfmt", "actionlint" })
    end,
  },
}
