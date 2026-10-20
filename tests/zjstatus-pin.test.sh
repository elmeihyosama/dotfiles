#!/usr/bin/env bash
# The pinned zellij minor has a zjstatus entry, so a Renovate minor bump fails
# here in seconds, not in the macOS provision job.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$TESTS_REPO" || exit 1
ver="$(yq '.tools.zellij.version' home/.chezmoidata/tools.yaml)"
minor="$(printf '%s' "$ver" | sed -nE 's/^([0-9]+\.[0-9]+)\.[0-9]+.*/\1/p')"
[ -n "$minor" ] || fail "tools.yaml zellij version is X.Y.Z (got '$ver')"
keys="$(yq -r '.zjstatus_by_zellij_minor | keys | .[]' ansible/group_vars/all.yml)"
printf '%s\n' "$keys" | grep -qxF "$minor" ||
	fail "zellij $ver (tools.yaml) has no zjstatus_by_zellij_minor \"$minor\" entry in ansible/group_vars/all.yml: add one (see the comment there)"
# Every entry is a version plus a 64-hex sha256.
bad="$(yq -o json '.zjstatus_by_zellij_minor' ansible/group_vars/all.yml |
	jq -r 'to_entries[] | select((.value.version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$") | not) or (.value.sha256 | test("^[0-9a-f]{64}$") | not)) | .key')"
assert_eq "" "$bad" "every zjstatus_by_zellij_minor entry has a vX.Y.Z version and a sha256"
