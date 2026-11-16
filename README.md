# dotfiles

My terminal setup for macOS and Linux, managed with [chezmoi](https://chezmoi.io).

## Install

### macOS

```sh
# 1. Homebrew (https://brew.sh)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"

# 2. Config files
brew install chezmoi
chezmoi init --apply elmeihyosama

# 3. Tools, apps and font
brew bundle --file ~/.local/share/chezmoi/Brewfile
```

### Linux

Needs `zsh` and `git` first (`sudo apt install zsh git`).

```sh
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin init --apply elmeihyosama
```

Install the tools you want by hand (the [`Brewfile`](Brewfile) lists them).
The shell works without them: anything missing is skipped. Neovim also needs
`node` and `tree-sitter` to install its language servers and syntax parsers.

On a server where your login shell is bash and you can't change it, add this
to the end of `~/.bashrc` to switch to zsh when it's installed:

```sh
[ -x "$(command -v zsh)" ] && [ -t 1 ] && exec zsh -l
```

## Updating

```sh
chezmoi update        # pull and apply the latest dotfiles
brew upgrade          # macOS: tools and apps
```

Neovim plugins update from inside Neovim: `:Lazy update`.

## Per-machine files

Never committed; write them by hand on each machine.

`~/.config/git/local` — who you are on this machine (included at the end of
the shared git config):

```ini
[user]
    name = Your Name
    email = you@example.com
```

`~/.zshrc.local` — aliases and settings for this machine only, read last by `~/.zshrc`.

## Neovim

[LazyVim](https://lazyvim.org) with the official Catppuccin theme. On first
launch it downloads its plugins; the first file of each language then installs
that language's tools (`:Mason` shows them). Languages: Python, TypeScript /
JavaScript, C / C++, Bash, Docker, YAML, JSON, Markdown, Terraform, Ansible.

## Claude Code

Claude rewrites its own `settings.json`, so it isn't in this repo. To use the
status line from [`claude-statusline`](home/dot_local/bin/executable_claude-statusline),
add this to `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/.local/bin/claude-statusline" }
```

On a work machine, keep the work account in its own profile: add this to
`~/.zshrc.local`, and the same `statusLine` to `~/.claude-work/settings.json`.

```sh
alias claude-work='CLAUDE_CONFIG_DIR=$HOME/.claude-work claude'
```

## Layout

Everything chezmoi manages lives in [`home/`](home):

| File | What it sets up |
|---|---|
| `dot_zshenv` | environment for every zsh: XDG folders, PATH, editor |
| `dot_zprofile` | login shells: Homebrew on PATH (macOS) |
| `dot_zshrc` | interactive zsh: options, keys, completion, aliases, tools |
| `.chezmoiexternal.toml` | zsh plugins, cloned and refreshed weekly |
| `dot_config/starship.toml` | prompt |
| `dot_config/ghostty/` | terminal |
| `dot_config/herdr/` | terminal multiplexer |
| `dot_config/nvim/` | Neovim (LazyVim) |
| `dot_config/git/` | git settings and global ignore |
| `dot_config/atuin/` | shell history search |
| `dot_config/bat/`, `eza/`, `ripgrep/` | file viewer, `ls`, search |
| `dot_local/bin/claude-statusline` | Claude Code status line |

Colours everywhere are the official [Catppuccin](https://github.com/catppuccin) Mocha ports.
