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
{"tools": {"fzf": {"backend": "aqua:junegunn/fzf", "version": "0.67.0"}, "eza": {"backend": "github:eza-community/eza", "version": "0.23.4"}, "cava": {"native_only": true}, "mise": {"bootstrap": true, "version": "1.0.0"}}}
Y
cat >"$d/home.lock" <<'L'
[[tools."aqua:junegunn/fzf"]]
version = "0.67.0"
backend = "aqua:junegunn/fzf"

[[tools."github:eza-community/eza"]]
version = "0.23.4"
backend = "github:eza-community/eza"
L
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
		--mise-toml "$d/mise.toml" --repo-lock "$d/repo.lock" 2>&1)"
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
