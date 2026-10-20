#!/usr/bin/env bash
# The one way to refresh pins. From mise_version (and nerd_font_version,
# uv_version) in ansible/group_vars/all.yml it rewrites: mise_sha256, CI's mise
# pins (setup-lint, provision.yml's macos job), the repo mise.lock (pruning
# orphaned .mise/locks uv.lock dirs), the dotfiles lock, the nerd font sha256,
# uv_installer_sha256 and tools.yaml's bootstrap mise version.
# Idempotent; prints what changed. Every rewrite is re-read, so layout drift
# fails loudly. Needs: mise, chezmoi, yq, gh or curl.
# Usage: scripts/relock.sh   (after editing a version, or on a Renovate branch)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
GV=ansible/group_vars/all.yml
SETUP_LINT=.github/actions/setup-lint/action.yml
PROVISION=.github/workflows/provision.yml
REPO_LOCK=mise.lock
HOME_LOCK=home/dot_config/mise-dotfiles/mise.lock
PINS_TMPL=home/dot_config/mise-dotfiles/config.toml.tmpl
FONTS=ansible/tasks/fonts.yml
TOOLS=home/.chezmoidata/tools.yaml
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

# fetch_release_asset REPO TAG ASSET OUT: gh, falling back to curl.
fetch_release_asset() {
	if command -v gh >/dev/null 2>&1 && gh release download "$2" -R "$1" -p "$3" -O "$4" --clobber >/dev/null 2>&1; then :; else
		command -v curl >/dev/null 2>&1 || die "gh release download of $1 $2 $3 failed and curl is missing"
		curl -fsSL "https://github.com/$1/releases/download/$2/$3" -o "$4"
	fi
}

fetch_shasums() {
	SHASUMS="$tmp/SHASUMS256.txt"
	fetch_release_asset jdx/mise "v$MISE_VERSION" SHASUMS256.txt "$SHASUMS"
}

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

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

# set_ci_pin FILE SHA COMMENT-ASSET: rewrite the first `version:`, the next
# `sha256:` and its asset-name comment.
set_ci_pin() {
	local file="$1" sha="$2" asset="$3" out
	out="$tmp/ci.$(basename "$file")"
	awk -v ver="$MISE_VERSION" -v sha="$sha" -v asset="$asset" '
		!v && /^[[:space:]]*version:[[:space:]]*[0-9]/ {sub(/version:[[:space:]]*[0-9][^[:space:]]*/, "version: " ver); v=1; print; next}
		v && !s && /sha256 of mise-v/ {sub(/mise-v[0-9][^[:space:]]*/, asset)}
		v && !s && /^[[:space:]]*sha256:[[:space:]]*[0-9a-f]/ {sub(/sha256:[[:space:]]*[0-9a-f]+/, "sha256: " sha); s=1}
		{print}' "$file" >"$out"
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
	prune_orphan_uvlocks
}

# Same rule as check-lock-sync.sh (c): keep only uv.lock dirs the lock references.
prune_orphan_uvlocks() {
	local refs d rel
	refs="$(grep -o 'path = "[^"]*"' "$REPO_LOCK" | sed -e 's/^path = "//' -e 's/"$//')"
	for d in .mise/locks/pipx-*/*/; do
		[ -d "$d" ] || continue
		rel="${d%/}"
		printf '%s\n' "$refs" | grep -qxF "$rel" && continue
		rm -rf "$rel"
		rmdir "$(dirname "$rel")" 2>/dev/null || true
		say "$rel: REMOVED (no longer in $REPO_LOCK)"
		changed=1
	done
}

# Every tool with a backend (mise_pins_all ignores selection and OS), locked
# as machines read it: a throwaway pins dir as system config, global config
# masked, -C /, and `lock -g` (writes mise.lock beside the system config).
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

relock_nerd_font() {
	local font ver sums="$tmp/nerd-fonts-SHA-256.txt" sha out="$tmp/fonts.yml"
	font="$(sed -nE 's/^nerd_font:[[:space:]]*"([^"]+)".*/\1/p' "$GV")"
	ver="$(sed -nE 's/^nerd_font_version:[[:space:]]*"([^"]+)".*/\1/p' "$GV")"
	[ -n "$font" ] && [ -n "$ver" ] || die "nerd_font / nerd_font_version not found in $GV"
	fetch_release_asset ryanoasis/nerd-fonts "$ver" SHA-256.txt "$sums"
	sha="$(awk -v a="$font.zip" '$2==a {print $1; exit}' "$sums")"
	[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "no sha256 for $font.zip in nerd-fonts $ver SHA-256.txt"
	sed -E "s/(checksum:[[:space:]]*\"sha256:)[0-9a-f]{64}\"/\1$sha\"/" "$FONTS" >"$out"
	expect "$out" "checksum:[[:space:]]*\"sha256:$sha\"" "$FONTS nerd font checksum"
	replace_if_changed "$FONTS" "$out" "$FONTS nerd font sha256"
}

# uv publishes no checksum for uv-installer.sh; install.sh checks against this.
relock_uv_installer() {
	local ver inst="$tmp/uv-installer.sh" sha out="$tmp/all.uv.yml"
	ver="$(sed -nE 's/^uv_version:[[:space:]]*"([^"]+)".*/\1/p' "$GV")"
	[ -n "$ver" ] || die "uv_version not found in $GV"
	fetch_release_asset astral-sh/uv "$ver" uv-installer.sh "$inst"
	sha="$(sha256 "$inst")"
	[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "could not hash uv $ver uv-installer.sh"
	sed -E "s/^(uv_installer_sha256:[[:space:]]*\")[0-9a-f]*\"/\1$sha\"/" "$GV" >"$out"
	expect "$out" "^uv_installer_sha256:[[:space:]]*\"$sha\"" "$GV uv_installer_sha256"
	replace_if_changed "$GV" "$out" "$GV uv_installer_sha256"
}

# tools.yaml's bootstrap `mise:` entry carries mise_version too.
relock_tools_mise() {
	local out="$tmp/tools.yaml"
	awk -v ver="$MISE_VERSION" '
		/^  mise:$/ {f=1; print; next}
		f && /^  [^[:space:]]/ {f=0}
		f && /^    version:/ {sub(/"[^"]*"/, "\"" ver "\"")}
		{print}' "$TOOLS" >"$out"
	[ "$(yq '.tools.mise.version' "$out")" = "$MISE_VERSION" ] || die "$TOOLS: mise version did not land (layout changed?)"
	replace_if_changed "$TOOLS" "$out" "$TOOLS mise version"
}

fetch_shasums
relock_group_vars
relock_uv_installer
relock_tools_mise
relock_ci
relock_repo_lock
relock_home_lock
relock_nerd_font
if [ "$changed" -eq 0 ]; then
	say "nothing to change"
else
	say "done (files updated; review git diff)"
fi
