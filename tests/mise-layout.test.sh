#!/usr/bin/env bash
# Canary for the undocumented MISE_SYSTEM_CONFIG_DIR the dotfiles pins/lock rely on
# (layout spike, plan 03). In a throwaway HOME, with the repo's real rendered pins
# template and shipped lock and whatever mise is on PATH:
#   1. the user's own `mise use -g jq@1.7.1` succeeds,
#   2. the dotfiles locked install (user config masked) succeeds,
#   3. pins and lock are byte-identical afterwards (no chezmoi drift).
# Also dry-runs the full default pins for this platform. Downloads two small tools, so it SKIPs (exit 0) without mise or network.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v mise >/dev/null 2>&1 || {
	echo "SKIP: mise not on PATH"
	exit 0
}
command -v chezmoi >/dev/null 2>&1 || {
	echo "SKIP: chezmoi not on PATH"
	exit 0
}
if ! curl -fsS -m 8 -o /dev/null https://github.com 2>/dev/null; then
	echo "SKIP: no network"
	exit 0
fi

tmpl="$TESTS_REPO/home/dot_config/mise-dotfiles/config.toml.tmpl"
lock_src="$TESTS_REPO/home/dot_config/mise-dotfiles/mise.lock"

mk_home
# Fresh mise state, nothing inherited from the caller's environment.
export MISE_DATA_DIR="$HOME/.local/share/mise" MISE_CACHE_DIR="$HOME/.cache/mise" MISE_STATE_DIR="$HOME/.local/state/mise" MISE_YES=1
unset MISE_CONFIG_DIR MISE_GLOBAL_CONFIG_FILE MISE_ENV MISE_LOCKED MISE_SYSTEM_CONFIG_DIR
export MISE_SYSTEM_CONFIG_DIR="$HOME/.config/mise-dotfiles"
cfg="$MISE_SYSTEM_CONFIG_DIR/config.toml" lock="$MISE_SYSTEM_CONFIG_DIR/mise.lock"
mkdir -p "$MISE_SYSTEM_CONFIG_DIR"

# A small subset of the real template (fzf, fd); the lock stays the FULL shipped
# one, as on a machine with a partial selection.
render_tmpl "$tmpl" 'selected_tools=["fzf","fd"]' >"$cfg" || {
	fail "render pins template"
	exit 1
}
cp "$lock_src" "$lock"
cp "$cfg" "$HOME/pins.orig"
cp "$lock" "$HOME/lock.orig"

cd "$HOME" || exit 1
out="$(mise use -g jq@1.7.1 2>&1)" || fail "1. mise use -g jq@1.7.1 succeeds: $out"
out="$(MISE_GLOBAL_CONFIG_FILE=/nonexistent/mise-user.toml mise -C / install --locked 2>&1)" ||
	fail "2. dotfiles locked install succeeds: $out"
cmp -s "$HOME/pins.orig" "$cfg" || fail "3. pins byte-identical after use + install"
cmp -s "$HOME/lock.orig" "$lock" || {
	fail "3. lock byte-identical after use + install"
	diff "$HOME/lock.orig" "$lock" | head -10 >&2
}
# The user's global file got the user's tool, the dotfiles files did not.
assert_contains "$(cat "$HOME/.config/mise/config.toml" 2>/dev/null)" "jq" "user's mise use -g landed in their own config"
assert_not_contains "$(cat "$cfg")" "1.7.1" "dotfiles pins untouched by mise use -g"
# And the pinned tools really resolve through the dotfiles config.
fzf_v="$(mise -C / exec -- fzf --version 2>&1)" || fail "4. pinned fzf runs: $fzf_v"
assert_contains "$fzf_v" "0.67.0" "4. fzf resolves to the pinned version"

# 5. The full default selection for THIS platform resolves against the shipped
# lock: a dry-run locked install fails on any tool without a lock url here
# (e.g. an upstream with no asset for this OS/arch).
render_tmpl "$tmpl" >"$cfg" || fail "5. render full default pins"
out="$(MISE_GLOBAL_CONFIG_FILE=/nonexistent/mise-user.toml mise -C / install --locked --dry-run 2>&1)" ||
	fail "5. full default pins resolve against the shipped lock: $out"
cmp -s "$HOME/lock.orig" "$lock" || fail "5. lock unchanged by the dry run"
