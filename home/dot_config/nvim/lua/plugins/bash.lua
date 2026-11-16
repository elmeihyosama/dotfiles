-- no LazyVim extra for Bash: add its language server and linter
return {
  { "neovim/nvim-lspconfig", opts = { servers = { bashls = {} } } },
  { "mason-org/mason.nvim", opts = { ensure_installed = { "shellcheck" } } },
}
