#!/usr/bin/env bash
# The playbook's install mask hides ALL of the user's global mise config
# (config.toml, mise.toml, conf.d/*.toml). Offline: `config ls` only.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v mise >/dev/null 2>&1 || {
	echo "SKIP: no mise on PATH" >&2
	exit 0
}
mask="$(sed -nE "s/.*'MISE_GLOBAL_CONFIG_FILE': '([^']+)'.*/\1/p" "$TESTS_REPO/ansible/group_vars/all.yml")"
assert_contains "$mask" "/nonexistent/" "group_vars masks the global config with a nonexistent path"

mk_home
mkdir -p "$HOME/.config/mise/conf.d" "$HOME/.config/mise-dotfiles"
printf '[tools]\n"aqua:junegunn/fzf" = "0.67.0"\n' >"$HOME/.config/mise-dotfiles/config.toml"
printf '[tools]\njq = "1.7.1"\n' >"$HOME/.config/mise/conf.d/user.toml"
printf '[tools]\nfd = "10.2.0"\n' >"$HOME/.config/mise/config.toml"
printf '[tools]\nbat = "0.25.0"\n' >"$HOME/.config/mise/mise.toml"

ls_cfg() { # ls_cfg [ENV=VAL ...]
	(cd / && env -i HOME="$HOME" PATH="$PATH" MISE_OFFLINE=1 \
		MISE_DATA_DIR="$HOME/data" MISE_CACHE_DIR="$HOME/cache" MISE_STATE_DIR="$HOME/state" \
		MISE_SYSTEM_CONFIG_DIR="$HOME/.config/mise-dotfiles" "$@" mise -C / config ls 2>&1)
}
out="$(ls_cfg)"
assert_contains "$out" "conf.d/user.toml" "unmasked: conf.d is loaded (fixture sanity)"
out="$(ls_cfg MISE_GLOBAL_CONFIG_FILE="$mask")"
assert_contains "$out" "mise-dotfiles/config.toml" "masked: dotfiles pins loaded"
assert_not_contains "$out" "conf.d" "masked: conf.d not loaded"
assert_not_contains "$out" ".config/mise/config.toml" "masked: global config.toml not loaded"
assert_not_contains "$out" ".config/mise/mise.toml" "masked: global mise.toml not loaded"
