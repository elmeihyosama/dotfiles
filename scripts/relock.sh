#!/usr/bin/env bash
# The only blessed way to refresh pins. Reads mise_version from
# ansible/group_vars/all.yml and rewrites, together:
#   1. mise_sha256 (3 locked platforms) from the release's SHASUMS256.txt
#   2. CI's mise pins: setup-lint (version + linux-x64 sha256) and the macos job
#      in provision.yml (version + macos-arm64 sha256)
#   3. the repo mise.lock (`mise lock`)
# One function per artifact (more can be added). Idempotent: a second run is a
# no-op. Prints what changed. Respects the caller's MISE_* / GITHUB_TOKEN env.
# Usage: scripts/relock.sh   (edit mise_version first to bump)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
GV=ansible/group_vars/all.yml
SETUP_LINT=.github/actions/setup-lint/action.yml
PROVISION=.github/workflows/provision.yml
PLATFORMS=macos-arm64,linux-x64,linux-arm64
changed=0

say() { printf 'relock: %s\n' "$*"; }

# replace_if_changed FILE NEWCONTENTFILE LABEL
replace_if_changed() {
	if cmp -s "$1" "$2"; then
		say "$3: unchanged"
	else
		cp "$2" "$1"
		say "$3: UPDATED"
		changed=1
	fi
}

MISE_VERSION="$(sed -nE 's/^mise_version:[[:space:]]*"?([0-9][^"#[:space:]]*)"?.*/\1/p' "$GV")"
[ -n "$MISE_VERSION" ] || {
	echo "relock: mise_version not found in $GV" >&2
	exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fetch_shasums() {
	local f="$tmp/SHASUMS256.txt" url="https://github.com/jdx/mise/releases/download/v$MISE_VERSION/SHASUMS256.txt"
	if command -v gh >/dev/null 2>&1 && gh release download "v$MISE_VERSION" -R jdx/mise -p SHASUMS256.txt -O "$f" --clobber >/dev/null 2>&1; then :; else
		curl -fsSL "$url" -o "$f"
	fi
	SHASUMS="$f"
}

# asset_sha ASSET -> sha256 of that raw release binary
asset_sha() {
	local s
	s="$(awk -v a="./$1" -v b="$1" '$2==a || $2==b {print $1; exit}' "$SHASUMS")"
	[[ "$s" =~ ^[0-9a-f]{64}$ ]] || {
		echo "relock: no sha256 for $1 in SHASUMS256.txt (v$MISE_VERSION)" >&2
		exit 1
	}
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
	replace_if_changed "$file" "$out" "$file mise pin"
}

relock_ci() {
	local lx mac
	lx="$(asset_sha "mise-v$MISE_VERSION-linux-x64")"
	mac="$(asset_sha "mise-v$MISE_VERSION-macos-arm64")"
	set_ci_pin "$SETUP_LINT" "$lx" "mise-v$MISE_VERSION-linux-x64"
	set_ci_pin "$PROVISION" "$mac" "mise-v$MISE_VERSION-macos-arm64"
}

relock_repo_lock() {
	command -v mise >/dev/null 2>&1 || {
		echo "relock: mise not found on PATH" >&2
		exit 1
	}
	local before
	before="$(cksum <mise.lock)"
	mise lock --platform "$PLATFORMS" >/dev/null 2>&1
	if [ "$before" = "$(cksum <mise.lock)" ]; then
		say "mise.lock: unchanged"
	else
		say "mise.lock: UPDATED"
		changed=1
	fi
}

fetch_shasums
relock_group_vars
relock_ci
relock_repo_lock
if [ "$changed" -eq 0 ]; then
	say "nothing to change"
else
	say "done (files updated; review git diff)"
fi
