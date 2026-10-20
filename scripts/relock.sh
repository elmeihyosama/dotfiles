#!/usr/bin/env bash
# The only blessed way to refresh pins. Reads mise_version from
# ansible/group_vars/all.yml and rewrites, together:
#   1. mise_sha256 (3 locked platforms) from the release's SHASUMS256.txt
#   2. CI's mise pins: setup-lint (version + linux-x64 sha256) and the macos job
#      in provision.yml (version + macos-arm64 sha256)
#   3. the repo mise.lock (`mise lock`)
#   4. the shipped dotfiles lock, home/dot_config/mise-dotfiles/mise.lock: every
#      tool in tools.yaml with a backend, rendered from the pins template into a
#      temp dir and locked there (never touches your own mise config)
# One function per artifact (more can be added). Idempotent: a second run is a
# no-op. Prints what changed. Respects the caller's MISE_* / GITHUB_TOKEN env.
# Every rewrite is re-read and checked, so workflow/YAML drift fails loudly
# instead of silently doing nothing. Needs: mise, chezmoi, yq, gh or curl.
# Usage: scripts/relock.sh   (edit mise_version first to bump)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
GV=ansible/group_vars/all.yml
SETUP_LINT=.github/actions/setup-lint/action.yml
PROVISION=.github/workflows/provision.yml
REPO_LOCK=mise.lock
HOME_LOCK=home/dot_config/mise-dotfiles/mise.lock
PINS_TMPL=home/dot_config/mise-dotfiles/config.toml.tmpl
PLATFORMS=macos-arm64,linux-x64,linux-arm64
changed=0

say() { printf 'relock: %s\n' "$*"; }
die() {
	printf 'relock: %s\n' "$*" >&2
	exit 1
}

# Preflight: check every tool before writing anything.
for c in mise chezmoi yq; do
	command -v "$c" >/dev/null 2>&1 || die "$c not found on PATH"
done
command -v gh >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || die "need gh or curl to fetch SHASUMS256.txt"

# replace_if_changed FILE NEWCONTENTFILE LABEL
replace_if_changed() {
	if [ -f "$1" ] && cmp -s "$1" "$2"; then
		say "$3: unchanged"
	else
		mkdir -p "$(dirname "$1")"
		cp "$2" "$1"
		say "$3: UPDATED"
		changed=1
	fi
}

# expect FILE REGEX LABEL: the rewritten content must contain REGEX (ERE).
expect() {
	grep -Eq -- "$2" "$1" || die "$3: expected '$2' in rewritten $(basename "$1") (YAML/workflow layout changed?)"
}

MISE_VERSION="$(sed -nE 's/^mise_version:[[:space:]]*"?([0-9][^"#[:space:]]*)"?.*/\1/p' "$GV")"
[ -n "$MISE_VERSION" ] || die "mise_version not found in $GV"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch_shasums() {
	local f="$tmp/SHASUMS256.txt" url="https://github.com/jdx/mise/releases/download/v$MISE_VERSION/SHASUMS256.txt"
	if command -v gh >/dev/null 2>&1 && gh release download "v$MISE_VERSION" -R jdx/mise -p SHASUMS256.txt -O "$f" --clobber >/dev/null 2>&1; then :; else
		command -v curl >/dev/null 2>&1 || die "gh release download failed and curl is missing"
		curl -fsSL "$url" -o "$f"
	fi
	SHASUMS="$f"
}

# asset_sha ASSET -> sha256 of that raw release binary
asset_sha() {
	local s
	s="$(awk -v a="./$1" -v b="$1" '$2==a || $2==b {print $1; exit}' "$SHASUMS")"
	[[ "$s" =~ ^[0-9a-f]{64}$ ]] || die "no sha256 for $1 in SHASUMS256.txt (v$MISE_VERSION)"
	printf '%s' "$s"
}

relock_group_vars() {
	local mac lx la out="$tmp/all.yml"
	mac="$(asset_sha "mise-v$MISE_VERSION-macos-arm64")"
	lx="$(asset_sha "mise-v$MISE_VERSION-linux-x64-musl")"
	la="$(asset_sha "mise-v$MISE_VERSION-linux-arm64-musl")"
	awk -v mac="$mac" -v lx="$lx" -v la="$la" '
		/^mise_sha256:/ {f=1; print; next}
		f && /^[^[:space:]#]/ {f=0}
		f && /^[[:space:]]+macos-arm64:/ {sub(/"[0-9a-f]+"/, "\"" mac "\"")}
		f && /^[[:space:]]+linux-x64:/ {sub(/"[0-9a-f]+"/, "\"" lx "\"")}
		f && /^[[:space:]]+linux-arm64:/ {sub(/"[0-9a-f]+"/, "\"" la "\"")}
		{print}' "$GV" >"$out"
	expect "$out" "^[[:space:]]+macos-arm64:[[:space:]]*\"$mac\"" "$GV macos-arm64"
	expect "$out" "^[[:space:]]+linux-x64:[[:space:]]*\"$lx\"" "$GV linux-x64"
	expect "$out" "^[[:space:]]+linux-arm64:[[:space:]]*\"$la\"" "$GV linux-arm64"
	replace_if_changed "$GV" "$out" "$GV mise_sha256"
}

# set_ci_pin FILE SHA COMMENT-ASSET: rewrite the first `version:` and the
# `sha256:` that follows the mise-action step, plus the asset-name comment.
set_ci_pin() {
	local file="$1" sha="$2" asset="$3" out
	out="$tmp/ci.$(basename "$file")"
	awk -v ver="$MISE_VERSION" -v sha="$sha" -v asset="$asset" '
		!v && /^[[:space:]]*version:[[:space:]]*[0-9]/ {sub(/version:[[:space:]]*[0-9][^[:space:]]*/, "version: " ver); v=1; print; next}
		v && !s && /sha256 of mise-v/ {sub(/mise-v[0-9][^[:space:]]*/, asset)}
		v && !s && /^[[:space:]]*sha256:[[:space:]]*[0-9a-f]/ {sub(/sha256:[[:space:]]*[0-9a-f]+/, "sha256: " sha); s=1}
		{print}' "$file" >"$out"
	# Re-read: the FIRST version: line and the first sha256: line must now be ours.
	[ "$(grep -E '^[[:space:]]*version:[[:space:]]*[0-9]' "$out" | head -1 | sed -E 's/.*version:[[:space:]]*//')" = "$MISE_VERSION" ] ||
		die "$file: version pin did not land (layout changed?)"
	[ "$(grep -E '^[[:space:]]*sha256:[[:space:]]*[0-9a-f]' "$out" | head -1 | sed -E 's/.*sha256:[[:space:]]*//')" = "$sha" ] ||
		die "$file: sha256 pin did not land (layout changed?)"
	replace_if_changed "$file" "$out" "$file mise pin"
}

relock_ci() {
	local lx mac
	lx="$(asset_sha "mise-v$MISE_VERSION-linux-x64")"
	mac="$(asset_sha "mise-v$MISE_VERSION-macos-arm64")"
	set_ci_pin "$SETUP_LINT" "$lx" "mise-v$MISE_VERSION-linux-x64"
	set_ci_pin "$PROVISION" "$mac" "mise-v$MISE_VERSION-macos-arm64"
}

# lock_changed LOCKFILE LABEL BEFORE: compare a checksum taken before the run.
lock_changed() {
	if [ "$3" = "$(cksum <"$1")" ]; then
		say "$2: unchanged"
	else
		say "$2: UPDATED"
		changed=1
	fi
}

relock_repo_lock() {
	local before=missing
	[ -f "$REPO_LOCK" ] && before="$(cksum <"$REPO_LOCK")"
	mise lock --platform "$PLATFORMS" >/dev/null
	[ -f "$REPO_LOCK" ] || die "mise lock did not produce $REPO_LOCK"
	lock_changed "$REPO_LOCK" "$REPO_LOCK" "$before"
}

# The dotfiles lock covers EVERY tool with a backend (the template's
# mise_pins_all knob ignores selection and OS), so a machine's subset and any
# OS find their entries. Locked in a throwaway MISE_SYSTEM_CONFIG_DIR with the
# user's global config masked, exactly as documented in the layout spike.
relock_home_lock() {
	local d="$tmp/home-pins" cfg="$tmp/pins-render.toml"
	mkdir -p "$d"
	printf '[data]\n    mise_pins_all = true\n' >"$cfg"
	chezmoi execute-template --source "$REPO" --config "$cfg" <"$PINS_TMPL" >"$d/config.toml"
	[ "$(yq -p toml '.tools | length' "$d/config.toml")" -gt 0 ] || die "pins render for $HOME_LOCK has no tools"
	MISE_SYSTEM_CONFIG_DIR="$d" MISE_GLOBAL_CONFIG_FILE=/nonexistent/none.toml \
		mise -C / lock -g --platform "$PLATFORMS" >/dev/null
	[ -s "$d/mise.lock" ] || die "mise lock did not write $d/mise.lock"
	replace_if_changed "$HOME_LOCK" "$d/mise.lock" "$HOME_LOCK"
}

fetch_shasums
relock_group_vars
relock_ci
relock_repo_lock
relock_home_lock
if [ "$changed" -eq 0 ]; then
	say "nothing to change"
else
	say "done (files updated; review git diff)"
fi
