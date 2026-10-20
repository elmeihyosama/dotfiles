#!/usr/bin/env bash
# scripts/check-lock-sync.sh: tools.yaml / mise.toml pins must appear in their locks.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$TESTS_REPO/scripts/check-lock-sync.sh"
d="$(mktemp -d)"
_tests_tmpdirs+=("$d")

# A tiny repo: tools.yaml (two tools), home lock, mise.toml, repo lock.
mkdir -p "$d/tools" "$d/mise-locks"
cat >"$d/tools.yaml" <<'Y'
{"tool_groups": ["core"], "tools": {"fzf": {"group": "core", "backend": "aqua:junegunn/fzf", "version": "0.67.0"}, "eza": {"group": "core", "backend": "github:eza-community/eza", "version": "0.23.4"}, "cava": {"group": "core", "native_only": true}, "mise": {"group": "core", "bootstrap": true, "version": "1.0.0", "backend": "aqua:jdx/mise"}}}
Y
# plat KEY PLATFORM: a platform entry with an OS-named asset url and a checksum
plat() {
	local asset
	case "$2" in
	macos-arm64) asset=x-darwin_arm64.tar.gz ;;
	linux-x64) asset=x-linux_amd64.tar.gz ;;
	*) asset=x-linux_arm64.tar.gz ;;
	esac
	printf '[tools."%s"."platforms.%s"]\nurl = "https://example.invalid/%s"\nchecksum = "sha256:00"\n\n' "$1" "$2" "$asset"
}
{
	printf '[[tools."aqua:junegunn/fzf"]]\nversion = "0.67.0"\nbackend = "aqua:junegunn/fzf"\n\n'
	for p in macos-arm64 linux-x64 linux-arm64; do plat aqua:junegunn/fzf $p; done
	printf '[[tools."github:eza-community/eza"]]\nversion = "0.23.4"\nbackend = "github:eza-community/eza"\n\n'
	for p in macos-arm64 linux-x64 linux-arm64; do plat github:eza-community/eza $p; done
} >"$d/home.lock"
cp "$d/home.lock" "$d/home.lock.orig"
: >"$d/exceptions.txt"
: >"$d/arch-exceptions.txt"
cat >"$d/mise.toml" <<'T'
[tools]
"aqua:mvdan/sh" = "3.14.1"
"github:editorconfig-checker/editorconfig-checker" = { version = "4.0.2", rename_exe = "ec" }
"pipx:pre-commit" = "4.7.0"
python = "3.13.16"
T
cat >"$d/repo.lock" <<'L'
[[tools."aqua:mvdan/sh"]]
version = "3.14.1"

[[tools."github:editorconfig-checker/editorconfig-checker"]]
version = "4.0.2"

[[tools."pipx:pre-commit"]]
version = "4.7.0"
uv = { path = ".mise/locks/pipx-pre-commit/4.7.0", digest = "sha256:aa" }

[[tools.python]]
version = "3.13.16"
L
mkdir -p "$d/.mise/locks/pipx-pre-commit/4.7.0"

run() {
	out="$(bash "$script" --root "$d" --tools "$d/tools.yaml" --home-lock "$d/home.lock" \
		--mise-toml "$d/mise.toml" --repo-lock "$d/repo.lock" --home-exceptions "$d/exceptions.txt" \
		--arch-exceptions "$d/arch-exceptions.txt" 2>&1)"
	rc=$?
}

run
assert_eq 0 "$rc" "in_sync_passes: exit 0"

# version_without_lock_fails: bump a tools.yaml version
sed -i.bak 's/0.23.4/0.24.0/' "$d/tools.yaml"
run
assert_eq 1 "$rc" "version_without_lock_fails: exit 1"
assert_contains "$out" "github:eza-community/eza" "version_without_lock_fails: names the tool"
assert_contains "$out" "run scripts/relock.sh" "version_without_lock_fails: hint"
mv "$d/tools.yaml.bak" "$d/tools.yaml"

# platform_asset_missing_fails: fzf has no linux-arm64 asset in the lock
awk '/^\[tools."aqua:junegunn\/fzf"."platforms.linux-arm64"\]/ {skip=4} skip>0 {skip--; next} {print}' "$d/home.lock.orig" >"$d/home.lock"
run
assert_eq 1 "$rc" "platform_asset_missing_fails: exit 1"
assert_contains "$out" "fzf" "platform_asset_missing_fails: names the tool"
assert_contains "$out" "linux-arm64" "platform_asset_missing_fails: names the platform"
# ... unless tools.yaml says so (missing_on), or the tool is native on that OS
sed -i.bak 's/"version": "0.67.0"/"version": "0.67.0", "missing_on": ["linux-arm64"]/' "$d/tools.yaml"
run
assert_eq 0 "$rc" "missing_on_exempts_platform: exit 0 ($out)"
mv "$d/tools.yaml.bak" "$d/tools.yaml"
cp "$d/home.lock.orig" "$d/home.lock"

# platform_checksum_missing_fails: fzf's linux-x64 entry has a url but no checksum
awk '/^\[tools."aqua:junegunn\/fzf"."platforms.linux-x64"\]/ {p=1} p && /^checksum/ {p=0; next} {print}' "$d/home.lock.orig" >"$d/home.lock"
run
assert_eq 1 "$rc" "platform_checksum_missing_fails: exit 1"
assert_contains "$out" "fzf (aqua:junegunn/fzf@0.67.0) has no linux-x64 checksum" "platform_checksum_missing_fails: names tool and platform"
# ... unless the home exceptions file lists that tool and platform
printf 'aqua:junegunn/fzf linux-x64  # no checksum upstream\n' >"$d/exceptions.txt"
run
assert_eq 0 "$rc" "checksum_exception_exempts_platform: exit 0 ($out)"
# an exception for another platform does not cover it
printf 'aqua:junegunn/fzf linux-arm64  # no checksum upstream\n' >"$d/exceptions.txt"
run
assert_eq 1 "$rc" "exception_for_other_platform: still fails"
: >"$d/exceptions.txt"
cp "$d/home.lock.orig" "$d/home.lock"

# platform_url_wrong_os_fails: the macos-arm64 url is a Linux asset (or a man
# page, or anything without the platform's OS in its name)
sed 's|"https://example.invalid/x-darwin_arm64.tar.gz"|"https://example.invalid/x-linux_amd64.tar.gz"|' "$d/home.lock.orig" >"$d/home.lock"
run
assert_eq 1 "$rc" "platform_url_wrong_os_fails: exit 1"
assert_contains "$out" "the macos-arm64 url does not look like a macos asset" "platform_url_wrong_os_fails: says why"
cp "$d/home.lock.orig" "$d/home.lock"

# platform_url_wrong_arch_fails: the macos-arm64 url is an Intel build, which
# needs Rosetta 2 (absent on a fresh Apple Silicon Mac)
for a in x-x86_64-apple-darwin.tar.gz x_Darwin_amd64.tar.gz x-macos-intel.zip x-macos-x64.tar.gz; do
	sed "s|\"https://example.invalid/x-darwin_arm64.tar.gz\"|\"https://example.invalid/$a\"|" "$d/home.lock.orig" >"$d/home.lock"
	run
	assert_eq 1 "$rc" "platform_url_wrong_arch_fails ($a): exit 1"
	assert_contains "$out" "the macos-arm64 url is an x86_64 asset ($a)" "platform_url_wrong_arch_fails ($a): says why"
done
# ... unless the arch exceptions file lists the tool and platform (both fake
# tools share the asset name, so list both)
printf '%s macos-arm64  # x86_64 only upstream; Rosetta required\n' aqua:junegunn/fzf github:eza-community/eza >"$d/arch-exceptions.txt"
run
assert_eq 0 "$rc" "arch_exception_exempts_platform: exit 0 ($out)"
: >"$d/arch-exceptions.txt"
# universal and arch-less macOS assets are fine
for a in x-universal-apple-darwin.tar.gz x-darwin-x86_64-arm64-universal.tar.gz x-apple-darwin.tar.gz x-macos.zip x-darwin-all.tar.gz; do
	sed "s|\"https://example.invalid/x-darwin_arm64.tar.gz\"|\"https://example.invalid/$a\"|" "$d/home.lock.orig" >"$d/home.lock"
	run
	assert_eq 0 "$rc" "macos_universal_or_archless_ok ($a): exit 0 ($out)"
done
cp "$d/home.lock.orig" "$d/home.lock"

# repo mise.toml tool missing from the repo lock
sed -i.bak 's/3.14.1/3.15.0/' "$d/mise.toml"
run
assert_eq 1 "$rc" "repo_tool_without_lock_fails: exit 1"
assert_contains "$out" "aqua:mvdan/sh" "repo_tool_without_lock_fails: names the tool"
mv "$d/mise.toml.bak" "$d/mise.toml"

# orphaned pipx uv.lock dir
mkdir -p "$d/.mise/locks/pipx-pre-commit/4.6.0"
run
assert_eq 1 "$rc" "orphan_uvlock_fails: exit 1"
assert_contains "$out" ".mise/locks/pipx-pre-commit/4.6.0" "orphan_uvlock_fails: names the dir"
rmdir "$d/.mise/locks/pipx-pre-commit/4.6.0"
run
assert_eq 0 "$rc" "orphan removed: passes again"

# the real repo is in sync
out="$(bash "$script" 2>&1)"
assert_eq 0 "$?" "real repo in sync: $out"
