#!/bin/sh
# Preserve any pre-existing shell rc files before this repo's chezmoi-managed
# versions replace them.
#
# Idempotent twice over: chezmoi runs `run_once_` scripts exactly once per
# machine (so re-running `chezmoi apply` never re-triggers this), and each file
# is copied only when no backup already exists. So you get a single, original
# backup — never a fresh one on every run.
set -eu

any=0
for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.zprofile"; do
	[ -f "$f" ] || continue
	bak="$f.pre-dotfiles.bak"
	[ -e "$bak" ] && continue
	cp -p "$f" "$bak"
	if [ "$any" -eq 0 ]; then
		echo "Preserved your previous shell rc file(s) before applying dotfiles:"
		any=1
	fi
	echo "  $bak"
done
