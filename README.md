# dotfiles

My terminal setup for macOS and Linux, managed with [chezmoi](https://chezmoi.io).
Plain config files; nothing here installs anything by itself.

## Install

```sh
# 1. Config files (asks once whether this is a work machine)
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b ~/.local/bin init --apply elmeihyosama

# 2. CLI tools, no sudo needed
curl https://mise.run | sh && ~/.local/bin/mise install

# 3. macOS only: apps and font
brew bundle --file ~/.local/share/chezmoi/Brewfile
```

Linux needs `zsh` and `git` first (`sudo apt install zsh git` where you have sudo).

## Per-machine files

Never committed; write them by hand on each machine.

## Layout

Everything chezmoi manages lives in [`home/`](home).
