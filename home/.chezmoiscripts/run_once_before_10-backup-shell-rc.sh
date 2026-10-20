#!/bin/sh
# Back up pre-existing config to <path>.pre-dotfiles.bak before the first
# `chezmoi apply --force`, skipping anything already backed up. This list must
# track the managed paths in the source tree.
set -eu

any=0
for t in \
	"$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile" \
	"$HOME/.config/bat" "$HOME/.config/ghostty" "$HOME/.config/git" \
	"$HOME/.config/lazygit" "$HOME/.config/navi" "$HOME/.config/nvim" \
	"$HOME/.config/ripgrep" "$HOME/.config/sheldon" "$HOME/.config/starship.toml" \
	"$HOME/.config/yazi" "$HOME/.config/zellij" "$HOME/.config/zsh"; do
	[ -e "$t" ] || continue
	bak="$t.pre-dotfiles.bak"
	[ -e "$bak" ] && continue
	cp -Rp "$t" "$bak"
	if [ "$any" -eq 0 ]; then
		echo "Preserved pre-existing config as *.pre-dotfiles.bak before applying dotfiles:"
		any=1
	fi
	echo "  $bak"
done
