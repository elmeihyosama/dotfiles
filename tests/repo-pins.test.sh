#!/usr/bin/env bash
# Tools pinned in both the repo toolchain (mise.toml) and the dotfiles
# (tools.yaml) share one version, so CI tests what machines run.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$TESTS_REPO" || exit 1
repo="$(yq -p toml -o json '.tools' mise.toml)"
shared=0
while IFS=$'\t' read -r name backend version; do
	pin="$(jq -r --arg k "$backend" '.[$k] // empty | if type == "object" then .version else . end' <<<"$repo")"
	[ -n "$pin" ] || continue
	shared=$((shared + 1))
	assert_eq "$version" "$pin" "$name: mise.toml $backend equals tools.yaml"
done < <(yq -o json '.tools' home/.chezmoidata/tools.yaml |
	jq -r 'to_entries[] | select(.value.backend) | [.key, .value.backend, .value.version] | @tsv')
[ "$shared" -ge 3 ] || fail "expected chezmoi/age/neovim in both (found $shared)"
