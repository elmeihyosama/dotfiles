#!/usr/bin/env sh
# doctor.sh: read-only health check for a provisioned machine. One
# OK/WARN/FAIL line per check; exits non-zero iff any FAIL.
# Usage: scripts/doctor.sh [--local LOCAL_YML] [--tools TOOLS_YAML]
#   (both passed on to assert-tools.sh, the same check CI runs)
set -eu

repo_root="$(CDPATH='' cd "$(dirname "$0")/.." && pwd)"
local_yml="$repo_root/ansible/local.yml"
tools_yaml="$repo_root/home/.chezmoidata/tools.yaml"
usage() {
	echo "usage: doctor.sh [--local LOCAL_YML] [--tools TOOLS_YAML]" >&2
	exit 2
}
while [ $# -gt 0 ]; do
	[ $# -ge 2 ] || usage
	case "$1" in
	--local) local_yml="$2" ;;
	--tools) tools_yaml="$2" ;;
	*) usage ;;
	esac
	shift 2
done
# Absolute paths: both are read after the cd / below.
abspath() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac }
local_yml="$(abspath "$local_yml")"
tools_yaml="$(abspath "$tools_yaml")"
case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
# shellcheck source=remove-hint.sh
. "$repo_root/scripts/remove-hint.sh"
# shellcheck source=mise-env.sh
. "$repo_root/scripts/mise-env.sh"
# From /, so mise shims answer with the home pins, never a project mise.toml.
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
# The pinned bootstrap binary must be the right version AND the mise PATH runs:
# the playbook cannot fix a different mise ahead of it (Homebrew's, a distro's).
want_mise="$(sed -nE 's/^mise_version:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$repo_root/ansible/group_vars/all.yml")"
lbin="$HOME/.local/bin"
[ -z "$(mise_sfx "$local_yml")" ] || lbin="$HOME/.local/bin-$arch"
pinned_mise="$lbin/mise"
mise_ver() { "$1" --version 2>/dev/null | awk 'NR == 1 { print $1 }'; }
if [ ! -x "$pinned_mise" ]; then
	bad "pinned mise missing at $pinned_mise (mise_version $want_mise; rerun the playbook: --tags mise)"
elif [ "$(mise_ver "$pinned_mise")" = "$want_mise" ]; then
	ok "mise $want_mise at $pinned_mise (ansible/group_vars mise_version)"
else
	bad "mise $(mise_ver "$pinned_mise") at $pinned_mise, but ansible/group_vars pins mise_version $want_mise (rerun the playbook: --tags mise)"
fi
if ! mise_bin="$(command -v mise 2>/dev/null)"; then
	bad "mise not on PATH (add $lbin to PATH)"
# Nothing can shadow a missing pin (already FAILed above).
elif [ -x "$pinned_mise" ] && [ "$mise_bin" != "$pinned_mise" ] && [ "$(resolve "$mise_bin")" != "$(resolve "$pinned_mise")" ]; then
	other="$(mise_ver "$mise_bin")"
	hint="$(remove_hint mise "$mise_bin")"
	hint="${hint:-take its dir off PATH, or put $lbin ahead of it}"
	if [ "$other" = "$want_mise" ]; then
		warn "mise $other at $mise_bin shadows the pinned $pinned_mise; remove it with: $hint"
	else
		bad "mise ${other:-?} at $mise_bin shadows the pinned $pinned_mise (mise_version $want_mise); remove it with: $hint"
	fi
fi

# --- Tools -----------------------------------------------------------------
# assert-tools' WARN lines (shadowed non-mise copies) are surfaced here.
if tools_out="$("$repo_root/.github/scripts/assert-tools.sh" --local "$local_yml" --tools "$tools_yaml" 2>&1)"; then
	ok "selected tools all present and runnable"
else
	bad "tool assertion failed:"
	# Everything but OK/SKIP/WARN, so a crash's error output shows too.
	printf '%s\n' "$tools_out" | grep -Ev '^(OK|SKIP|WARN):|^All tool assertions|^Tool assertions FAILED' | sed 's/^/      /'
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

# --- Commit signing (checked only when signing_key is set) ----------------
sk=""
if command -v chezmoi >/dev/null 2>&1; then
	sk="$(chezmoi execute-template '{{ get . "signing_key" }}' 2>/dev/null || true)"
fi
# gh_registered KEYFILE BODY: WARN/OK on GitHub registration. Never a FAIL, and
# bounded (DOCTOR_GH_TIMEOUT s, default 10) without timeout(1), absent on macOS.
gh_registered() {
	_skip="signing key registration not checked"
	command -v gh >/dev/null 2>&1 || {
		warn "$_skip (gh not installed)"
		return
	}
	gh auth token >/dev/null 2>&1 || {
		warn "$_skip (gh not authenticated)"
		return
	}
	_d="$(mktemp -d)"
	gh api user/ssh_signing_keys --jq '.[].key' >"$_d/out" 2>"$_d/err" &
	_p=$!
	(
		sleep "${DOCTOR_GH_TIMEOUT:-10}"
		kill "$_p" 2>/dev/null
	) >/dev/null 2>&1 &
	_w=$!
	_rc=0
	wait "$_p" || _rc=$?
	kill "$_w" 2>/dev/null || true
	if [ "$_rc" -eq 0 ]; then
		if grep -qF -- "$2" "$_d/out"; then
			ok "signing key registered on GitHub"
		else
			warn "signing key not registered on GitHub; run: gh ssh-key add $1 --type signing --title \"\$(hostname -s)\""
		fi
	elif grep -q 'admin:ssh_signing_key' "$_d/err"; then
		warn "$_skip (token lacks a scope; run: gh auth refresh -h github.com -s admin:ssh_signing_key)"
	elif grep -q 'HTTP 401' "$_d/err"; then
		warn "$_skip (gh not authenticated)"
	else
		warn "$_skip (offline)"
	fi
	rm -rf "$_d"
}
case "$sk" in
"") ;;
*.pub)
	case "$sk" in \~/*) sk="$HOME/${sk#\~/}" ;; esac
	if [ ! -f "$sk" ]; then
		bad "signing key $sk is missing (generate it: ssh-keygen -t ed25519 -f ${sk%.pub})"
	else
		read -r kt kb _ <"$sk" || true
		kb="$(printf '%s' "${kb:-}" | tr -d '\r')"
		case "${kt:-}" in
		ssh-* | ecdsa-* | sk-*) [ -z "$kb" ] || valid=1 ;;
		esac
		if [ "${valid:-0}" -ne 1 ]; then
			bad "signing key $sk is not a valid public key (empty or malformed)"
		else
			ok "signing key $sk present"
			gh_registered "$sk" "$kb"
		fi
	fi
	;;
*)
	bad "signing_key $sk must be the public key (a .pub file), not the private key (set it in ansible/local.yml)"
	;;
esac

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
