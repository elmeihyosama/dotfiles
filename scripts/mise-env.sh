#!/usr/bin/env sh
# mise-env.sh — sourced (POSIX sh) by .github/scripts/assert-tools.sh,
# scripts/doctor.sh and scripts/dotfiles.sh: the mise environment the dotfiles
# pins are read with. Same layout as ansible/group_vars/all.yml (mise_env).
# Keeping it in one place matters: it masks the user's global mise config, and
# drift would let a project mise.toml or `mise use -g` answer for a home tool.

# mise_sfx LOCAL_YML: "-<arch>" under shared_home, else nothing
mise_sfx() {
	if [ -f "$1" ] && grep -Eq '^[[:space:]]*shared_home:[[:space:]]*true' "$1"; then
		printf -- '-%s' "$(uname -m)"
	fi
}

# mise_env LOCAL_YML: set sfx and user_global, and export MISE_SYSTEM_CONFIG_DIR
# (dotfiles pins), MISE_DATA_DIR (per-arch under shared_home) and
# MISE_GLOBAL_CONFIG_FILE (masked). user_global is the user's own global config
# (what `mise use -g` writes) before masking, so an override there can be
# reported as such. Callers run mise as `mise -C /`.
# shellcheck disable=SC2034 # sfx, user_global: read by the sourcing script
mise_env() {
	sfx="$(mise_sfx "$1")"
	export MISE_SYSTEM_CONFIG_DIR="${MISE_SYSTEM_CONFIG_DIR:-$HOME/.config/mise-dotfiles}"
	export MISE_DATA_DIR="${MISE_DATA_DIR:-$HOME/.local/share$sfx/mise}"
	user_global="${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/config.toml}"
	export MISE_GLOBAL_CONFIG_FILE=/nonexistent/mise-user.toml
}
