#!/usr/bin/env sh
# doctor.sh — read-only health check for a provisioned machine.
# Sections: PATH, mise version, tools (via assert-tools.sh — same source of
# truth as CI), Nerd Font, chezmoi drift, active theme, login shell, zellij plugin.
# One OK/WARN/FAIL line per check; exits non-zero iff any FAIL.
# Usage: scripts/doctor.sh [--tools TOOLS_YAML]  (or the `doctor` shell function)
#   --tools  passed to assert-tools.sh (tests use a small catalog)
set -eu

repo_root="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)"
tools_arg=""
case "${1:-}" in
--tools)
	[ $# -ge 2 ] || {
		echo "usage: doctor.sh [--tools TOOLS_YAML]" >&2
		exit 2
	}
	tools_arg="$2"
	;;
"") ;;
*)
	echo "usage: doctor.sh [--tools TOOLS_YAML]" >&2
	exit 2
	;;
esac
# Run from / so that tools resolved through mise shims (chezmoi, jq) answer
# with the dotfiles' home pins, never a project mise.toml such as the repo's.
cd /
fail=0
ok() { printf 'OK    %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
bad() {
	printf 'FAIL  %s\n' "$1"
	fail=1
}

arch="$(uname -m)"

# --- PATH ------------------------------------------------------------------
# Accept the plain dir or the arch-suffixed variant used on shared homes.
case ":$PATH:" in
*":$HOME/.local/bin:"* | *":$HOME/.local/bin-$arch:"*)
	ok "user-local bin dir on PATH"
	;;
*)
	bad "neither ~/.local/bin nor ~/.local/bin-$arch on PATH"
	;;
esac

# --- mise ------------------------------------------------------------------
# The bootstrap binary is pinned in ansible/group_vars (tasks/mise.yml).
want_mise="$(sed -nE 's/^mise_version:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$repo_root/ansible/group_vars/all.yml")"
if mise_bin="$(command -v mise 2>/dev/null)"; then
	have_mise="$(mise --version 2>/dev/null | awk 'NR == 1 { print $1 }')"
	if [ "$have_mise" = "$want_mise" ]; then
		ok "mise $have_mise (ansible/group_vars mise_version)"
	else
		bad "mise ${have_mise:-?} at $mise_bin, but ansible/group_vars pins mise_version $want_mise (rerun the playbook: --tags mise)"
	fi
else
	bad "mise not on PATH (ansible/group_vars pins mise_version $want_mise)"
fi

# --- Tools -----------------------------------------------------------------
# assert-tools resolves the home pins from / with the user's global mise config
# masked; its WARN lines (non-mise copies shadowed on PATH) are surfaced here.
if tools_out="$("$repo_root/.github/scripts/assert-tools.sh" ${tools_arg:+--tools "$tools_arg"} 2>&1)"; then
	ok "selected tools all present and runnable"
else
	bad "tool assertion failed:"
	printf '%s\n' "$tools_out" | grep -E '^FAIL' | sed 's/^/      /'
fi
printf '%s\n' "$tools_out" | sed -n 's/^WARN: //p' | while IFS= read -r w; do warn "$w"; done

# --- Nerd Font -------------------------------------------------------------
if [ "$(uname -s)" = "Darwin" ]; then
	font_dir="$HOME/Library/Fonts"
else
	font_dir="$HOME/.local/share/fonts"
fi
if find "$font_dir" -name '*NerdFont*' 2>/dev/null | grep -q .; then
	ok "Nerd Font installed in $font_dir"
else
	bad "no Nerd Font found in $font_dir"
fi

# --- chezmoi ---------------------------------------------------------------
if command -v chezmoi >/dev/null 2>&1; then
	drift="$(chezmoi status 2>/dev/null || true)"
	if [ -z "$drift" ]; then
		ok "chezmoi: no drift (targets match source)"
	else
		warn "chezmoi: drift in $(printf '%s\n' "$drift" | wc -l | tr -d ' ') file(s) — run 'chezmoi diff'"
	fi

	if command -v jq >/dev/null 2>&1; then
		slug="$(chezmoi data --format json 2>/dev/null | jq -r '.theme // empty' || true)"
		if [ -n "$slug" ] && [ -f "$repo_root/home/.chezmoidata/themes/$slug.toml" ]; then
			ok "active theme '$slug' resolves to a vendored palette"
		elif [ -n "$slug" ]; then
			bad "active theme '$slug' has no palette in home/.chezmoidata/themes/"
		else
			bad "no active theme in chezmoi data"
		fi
	fi
else
	bad "chezmoi not on PATH"
fi

# --- age secrets (checked only when encryption is enabled) -----------------
if [ -f "$HOME/.config/chezmoi/chezmoi.toml" ] &&
	grep -q '^encryption = "age"' "$HOME/.config/chezmoi/chezmoi.toml"; then
	if [ -f "$HOME/.config/chezmoi/key.txt" ]; then
		ok "age encryption enabled and identity key present"
	else
		bad "age encryption enabled but ~/.config/chezmoi/key.txt is missing (apply will fail on encrypted files)"
	fi
fi

# --- Login shell -----------------------------------------------------------
case "${SHELL:-}" in
*/zsh)
	ok "login shell is zsh"
	;;
*)
	warn "login shell is '${SHELL:-unset}' (expected zsh; no-sudo hosts hop via the bashrc shim)"
	;;
esac

# --- zellij statusbar plugin ----------------------------------------------
if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/zellij/plugins/zjstatus.wasm" ]; then
	ok "zjstatus.wasm present"
else
	warn "zjstatus.wasm missing (zellij statusbar will not render; rerun the playbook)"
fi

if [ "$fail" -eq 0 ]; then
	printf '\ndoctor: healthy\n'
else
	printf '\ndoctor: problems found\n'
fi
exit "$fail"
