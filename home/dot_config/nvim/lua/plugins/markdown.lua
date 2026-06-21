-- In-editor markdown rendering (headings, tables, code blocks, lists, checkboxes)
-- right in the buffer — no browser. The line under the cursor shows raw markdown;
-- everything else renders. Toggle with `:RenderMarkdown toggle`.
return {
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown", "markdown_inline" },
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    opts = {},
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "markdown", "markdown_inline" } },
  },
}
