#!/usr/bin/env bash
# Usage: check-lock.sh LOCKFILE [TOOLS_YAML]
#
# Gates a mise.lock: every tool needs a checksum for each locked platform, so a
# fresh machine never installs something unverified. pipx tools need a uv.lock
# digest instead (their hash-pinned .mise/locks/**/uv.lock covers them).
# With TOOLS_YAML (home/.chezmoidata/tools.yaml): platforms where select-tools
# does not install the tool from mise are skipped, and a tool's
# `no_checksum_on: [platform, ...]  # reason` allows a gap there. An entry
# whose checksum now exists fails, so the list cannot rot.
#
# Output lines (a contract; other scripts and tests match them):
#   MISSING X P           tool X has no checksum for platform P
#   STALE-EXCEPTION X P   X P is in no_checksum_on but not needed there
# Exit 0 ok, 1 problems, 2 usage or bad no_checksum_on.
set -uo pipefail

lock="${1:-}"
tools="${2:-}"
if [ -z "$lock" ] || [ ! -f "$lock" ]; then
	echo "usage: check-lock.sh LOCKFILE [TOOLS_YAML]" >&2
	exit 2
fi

# One "tool<TAB>platform<TAB>true|false" row per tool/platform. A tool is
# covered only if every [[tools.X]] element has the checksum (a tool can appear
# more than once); a lone table is treated as a single element.
# shellcheck disable=SC2016  # $k/$els/$p are yq variables, not shell
rows="$(yq -p toml -o tsv '
	.tools // {} | to_entries | .[] | .key as $k |
	((.value | select(tag == "!!seq")) // [.value]) as $els |
	if ($k | test("^pipx:")) then [$k, "uv.lock digest", ($els | map(.uv.digest != null) | all)]
	else ("macos-arm64", "linux-x64", "linux-arm64") as $p |
		[$k, $p, ($els | map(.["platforms." + $p].checksum != null) | all)]
	end
' "$lock")" || {
	echo "check-lock: cannot parse $lock" >&2
	exit 2
}

# policy: "backend<TAB>platform<TAB>name<TAB>state" per tools.yaml tool; state is
# "skip" when mise does not install it there, plus "nocs" if in no_checksum_on.
policy=""
if [ -n "$tools" ]; then
	[ -f "$tools" ] || {
		echo "check-lock: no such tools file: $tools" >&2
		exit 2
	}
	bad="$(yq -r '.tools | to_entries[] | select(.value.no_checksum_on != null) |
		select((.value.no_checksum_on | line_comment) == "" or
			([.value.no_checksum_on[] | select(. != "macos-arm64" and . != "linux-x64" and . != "linux-arm64")] | length > 0)) | .key + ".no_checksum_on"' "$tools")" || exit 2
	if [ -n "$bad" ]; then
		echo "check-lock: $tools: each no_checksum_on needs locked platforms only and a trailing # reason:" >&2
		echo "$bad" >&2
		exit 2
	fi
	sel_tools="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/select-tools.sh"
	tools_json="$(yq -o json '.tools' "$tools")" || exit 2
	for p in macos-arm64 linux-x64 linux-arm64; do
		sel="$("$sel_tools" --platform "$p" --local /nonexistent --tools "$tools")" || exit 2
		policy+="$(jq -r --argjson sel "$sel" --arg p "$p" '
			to_entries[] | select(.value.backend != null) | .key as $n | .value as $t
			| any($sel[]; .name == $n and .source == "mise") as $mise
			| ((($t.no_checksum_on // []) | index($p)) != null) as $nocs
			| [$t.backend, $p, $n, ((if $mise then "" else "skip" end) + (if $nocs then "nocs" else "" end))]
			| @tsv' <<<"$tools_json")"$'\n'
	done
fi

status=0
while IFS=$'\t' read -r tool plat ok; do
	[ -n "$tool" ] || continue
	IFS=$'\t' read -r name state < <(awk -F'\t' -v t="$tool" -v p="$plat" \
		'$1 == t && $2 == p { print $3 "\t" $4; exit }' <<<"$policy")
	case "$state" in
	skip) continue ;;
	skipnocs)
		echo "STALE-EXCEPTION $tool $plat (not installed from mise there: remove $plat from $name.no_checksum_on in tools.yaml)"
		status=1
		;;
	nocs)
		if [ "$ok" = true ]; then
			echo "STALE-EXCEPTION $tool $plat (has a checksum now: remove $plat from $name.no_checksum_on in tools.yaml)"
			status=1
		fi
		;;
	*)
		if [ "$ok" = false ]; then
			echo "MISSING $tool $plat"
			status=1
		fi
		;;
	esac
done <<<"$rows"

exit "$status"
