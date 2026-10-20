#!/usr/bin/env bash
# Pinned mise bootstrap: group_vars pins an exact mise version plus one sha256
# per locked platform, and CI's two mise pins agree with it.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$TESTS_REPO" || exit 1
gv=ansible/group_vars/all.yml

ver="$(sed -nE 's/^mise_version:[[:space:]]*"?([^"#[:space:]]*)"?.*/\1/p' "$gv")"
if printf '%s' "$ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then :; else
	fail "mise_version is an exact version (got '$ver')"
fi

# mise_sha256 block: the keys under it, up to the next top-level key.
block="$(awk '/^mise_sha256:/ {f=1; next} f && /^[^[:space:]]/ {exit} f && /^[[:space:]]+[a-z]/' "$gv")"
keys="$(printf '%s\n' "$block" | sed -nE 's/^[[:space:]]+([a-z0-9-]+):.*/\1/p' | sort | tr '\n' ' ')"
assert_eq "linux-arm64 linux-x64 macos-arm64 " "$keys" "mise_sha256 has exactly the three locked platforms"
while IFS= read -r line; do
	[ -n "$line" ] || continue
	printf '%s' "$line" | grep -Eq ':[[:space:]]*"[0-9a-f]{64}"' || fail "mise_sha256 entry is 64 hex: $line"
done <<<"$block"

# CI pins must equal group_vars.
mise_ver() { grep -E '^[[:space:]]*version:[[:space:]]*[0-9]' "$1" | head -1 | sed -E 's/.*version:[[:space:]]*//'; }
assert_eq "$ver" "$(mise_ver .github/actions/setup-lint/action.yml)" "setup-lint version equals group_vars mise_version"
assert_eq "$ver" "$(mise_ver .github/workflows/provision.yml)" "macOS job version equals group_vars mise_version"

# The macOS job's sha is group_vars' macos-arm64 sha. setup-lint pins the
# linux-x64 glibc asset, which group_vars (musl) does not carry, so only its
# shape is checked below; relock.sh writes it from SHASUMS256.txt.
grep -Eq '^[[:space:]]*sha256:[[:space:]]*[0-9a-f]{64}$' .github/actions/setup-lint/action.yml || fail "setup-lint sha256 is 64 lowercase hex"
sha_of() { printf '%s\n' "$block" | sed -nE "s/^[[:space:]]+$1:[[:space:]]*\"([0-9a-f]{64})\".*/\1/p"; }
assert_eq "$(sha_of macos-arm64)" "$(grep -E '^[[:space:]]*sha256:' .github/workflows/provision.yml | head -1 | sed -E 's/.*sha256:[[:space:]]*//')" "macOS job sha256 equals mise_sha256.macos-arm64"

# Playbook wiring.
assert_contains "$(cat ansible/tasks/mise.yml 2>/dev/null)" "mise_sha256" "tasks/mise.yml uses mise_sha256"
site="$(cat ansible/site.yml)"
assert_contains "$site" "tasks/mise.yml" "site.yml imports tasks/mise.yml"
assert_contains "$site" "tags: [mise, packages]" "mise import is tagged (packages runs it too)"
mi="$(grep -n 'import_tasks: tasks/mise.yml' ansible/site.yml | head -1 | cut -d: -f1)"
pk="$(grep -n 'import_tasks: tasks/packages.yml' ansible/site.yml | head -1 | cut -d: -f1)"
[ -n "$mi" ] && [ -n "$pk" ] && [ "$mi" -lt "$pk" ] || fail "mise import precedes packages"

# relock.sh is executable and parses (running it needs the network).
[ -x scripts/relock.sh ] || fail "scripts/relock.sh is executable"
bash -n scripts/relock.sh || fail "scripts/relock.sh passes bash -n"
