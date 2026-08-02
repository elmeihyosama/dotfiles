#!/usr/bin/env sh
# doctor.sh — read-only health check for a provisioned machine.
# Sections: PATH, tools (via assert-tools.sh — same source of truth as CI),
# Nerd Font, chezmoi drift, active theme, login shell, zellij plugin.
# One OK/WARN/FAIL line per check; exits non-zero iff any FAIL.
# Usage: scripts/doctor.sh  (or the `doctor` shell function)
set -eu

repo_root="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)"
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

# --- Tools -----------------------------------------------------------------
if tools_out="$("$repo_root/.github/scripts/assert-tools.sh" "$repo_root/ansible/group_vars/all.yml" 2>&1)"; then
	ok "canonical tools all present and at floor versions"
else
	bad "tool assertion failed:"
	printf '%s\n' "$tools_out" | grep -v '^SKIP' | sed 's/^/      /'
fi

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
