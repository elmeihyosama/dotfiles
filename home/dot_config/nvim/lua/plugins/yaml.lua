-- Teach yaml-language-server about GitLab CI's custom `!reference` tag so it
-- stops flagging `.gitlab-ci.yml` (and other GitLab YAML) as an unknown tag.
return {
  "neovim/nvim-lspconfig",
  opts = {
    servers = {
      yamlls = {
        settings = {
          yaml = {
            customTags = {
              "!reference sequence",
            },
          },
        },
      },
    },
  },
}
