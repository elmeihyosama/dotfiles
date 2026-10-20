#!/usr/bin/env bash
# PATH precedence: the dotfiles' mise tools outrank ~/.local/bin and Homebrew,
# in `zsh -c` (shims from .zshenv) and `zsh -i` (00-env, then `mise activate`
# in 49-mise). A fake fzf sits in a Homebrew-like dir, in ~/.local/bin and in
# the mise shims dir; with a real mise on PATH, also in a fake mise install.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

mk_home
conf="$HOME/.config/zsh/conf.d"
mkdir -p "$conf" "$HOME/.local/bin" "$HOME/brew/bin" "$XDG_DATA_HOME/mise/shims"
render_tmpl "$TESTS_REPO/home/dot_zshenv.tmpl" >"$HOME/.zshenv" || fail "render .zshenv"
render_tmpl "$TESTS_REPO/home/dot_zshrc.tmpl" >"$HOME/.zshrc" || fail "render .zshrc"
render_tmpl "$TESTS_REPO/home/dot_config/zsh/conf.d/00-env.zsh.tmpl" >"$conf/00-env.zsh" || fail "render 00-env"
cp "$TESTS_REPO/home/dot_config/zsh/conf.d/49-mise.zsh" "$conf/"

fake() { # fake PATH LABEL
	printf '#!/bin/sh\necho %s\n' "$2" >"$1"
	chmod +x "$1"
}
fake "$HOME/brew/bin/fzf" brew
fake "$HOME/.local/bin/fzf" local-bin
fake "$XDG_DATA_HOME/mise/shims/fzf" mise-shim

shims="$XDG_DATA_HOME/mise/shims"
# run_fzf PATH ZSH-FLAGS...: what `fzf` resolves to in a clean env
run_fzf() {
	local p="$1"
	shift
	# cd: no repo mise.toml in scope (it is untrusted in a fresh HOME).
	(cd "$HOME" && env -i HOME="$HOME" PATH="$p" TERM=dumb MISE_OFFLINE=1 \
		zsh "$@" 'fzf' 2>/dev/null)
}

# The inherited PATH an interactive parent shell passes down: ~/.local/bin and
# brew ahead of the (already present) shims.
inherited="$HOME/.local/bin:$HOME/brew/bin:$shims:/usr/bin:/bin"
assert_eq mise-shim "$(run_fzf "$inherited" -c)" "zsh -c: mise shim wins over ~/.local/bin and brew"
assert_eq mise-shim "$(run_fzf "$HOME/brew/bin:/usr/bin:/bin" -c)" "zsh -c (fresh PATH): mise shim wins over brew"
assert_eq mise-shim "$(run_fzf "$HOME/brew/bin:/usr/bin:/bin" -i -c)" "zsh -i (no mise binary): mise shim wins"
assert_eq mise-shim "$(run_fzf "$inherited" -i -c)" "zsh -i (inherited PATH): mise shim wins"

# With a real mise: `mise activate` puts the pinned install dir first.
if real_mise="$(command -v mise)" && [ -x "$real_mise" ]; then
	mkdir -p "$HOME/misebin" "$HOME/.config/mise-dotfiles"
	ln -s "$real_mise" "$HOME/misebin/mise"
	inst="$XDG_DATA_HOME/mise/installs/aqua-junegunn-fzf/0.67.0"
	mkdir -p "$inst"
	fake "$inst/fzf" mise-install
	printf '[tools]\n"aqua:junegunn/fzf" = "0.67.0"\n' >"$HOME/.config/mise-dotfiles/config.toml"
	got="$(run_fzf "$HOME/.local/bin:$HOME/brew/bin:$HOME/misebin:/usr/bin:/bin" -i -c)"
	assert_eq mise-install "$got" "zsh -i with mise activate: pinned install dir wins"
else
	echo "SKIP: no mise on PATH (activation case)" >&2
fi
