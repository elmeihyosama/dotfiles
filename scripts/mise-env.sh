#!/usr/bin/env sh
# mise-env.sh: sourced by assert-tools.sh, doctor.sh and dotfiles.sh; the mise
# env the dotfiles pins are read with (as group_vars mise_env). One place on
# purpose: drift would let a project mise.toml or `mise use -g` answer.

# mise_sfx LOCAL_YML: "-<arch>" under shared_home, else nothing
mise_sfx() {
	if [ -f "$1" ] && grep -Eq '^[[:space:]]*shared_home:[[:space:]]*true' "$1"; then
		printf -- '-%s' "$(uname -m)"
	fi
}

# mise_env LOCAL_YML: set sfx and user_global (the global config before
# masking, so an override there can be reported), export the MISE_* vars.
# Callers run mise as `mise -C /`.
# shellcheck disable=SC2034 # sfx, user_global: read by the sourcing script
mise_env() {
	sfx="$(mise_sfx "$1")"
	export MISE_SYSTEM_CONFIG_DIR="${MISE_SYSTEM_CONFIG_DIR:-$HOME/.config/mise-dotfiles}"
	export MISE_DATA_DIR="${MISE_DATA_DIR:-$HOME/.local/share$sfx/mise}"
	user_global="${MISE_GLOBAL_CONFIG_FILE:-${MISE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/mise}/config.toml}"
	export MISE_GLOBAL_CONFIG_FILE=/nonexistent/mise-user.toml
}
