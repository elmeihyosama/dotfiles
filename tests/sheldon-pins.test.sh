#!/usr/bin/env bash
# Every networked sheldon plugin is pinned: a 40-hex `rev` or a `tag`, or for a
# remote URL a commit SHA or version tag in it, never a branch.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

f="$TESTS_REPO/home/dot_config/sheldon/plugins.toml"

# Prints "<plugin>\t<kind>\t<pin>" per networked plugin ("-" when unpinned).
rows="$(awk '
	function flush() { if (name != "" && kind != "") printf "%s\t%s\t%s\t%s\n", name, kind, rev, url; name = kind = rev = url = "" }
	/^\[/ { flush(); if ($0 ~ /^\[plugins\./) { name = $0; gsub(/^\[plugins\.|\]$/, "", name) } next }
	name != "" && /^(github|git)[[:space:]]*=/ { kind = "git" }
	name != "" && /^remote[[:space:]]*=/ { kind = "remote"; url = $0; sub(/^[^"]*"/, "", url); sub(/".*$/, "", url) }
	name != "" && /^rev[[:space:]]*=/ { rev = $0; sub(/^[^"]*"/, "", rev); sub(/".*$/, "", rev) }
	name != "" && /^tag[[:space:]]*=/ { rev = "tag:" $0; sub(/tag:[^"]*"/, "tag:", rev); sub(/".*$/, "", rev) }
	END { flush() }
' "$f")"

[ -n "$rows" ] || fail "no networked plugins found in plugins.toml"

while IFS=$'\t' read -r name kind pin url; do
	[ -n "$name" ] || continue
	if [ "$kind" = git ]; then
		case "$pin" in
		tag:?*) ;;
		*)
			grep -qE '^[0-9a-f]{40}$' <<<"$pin" || fail "plugin $name: needs rev = <40-hex sha> or tag (got '$pin')"
			;;
		esac
	else
		grep -qE '/[0-9a-f]{40}/|/v?[0-9]+\.[0-9]+(\.[0-9]+)?/' <<<"$url" || fail "plugin $name: remote URL must contain a commit SHA or version tag: $url"
	fi
done <<<"$rows"
