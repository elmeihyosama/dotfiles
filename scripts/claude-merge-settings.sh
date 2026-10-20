#!/usr/bin/env bash
# Usage: claude-merge-settings.sh SETTINGS_JSON BASELINE_JSON
# Additive merge of the baseline into a Claude settings.json, in place and
# atomic: statusLine replaced, enabledPlugins added only when absent,
# permissions.allow unioned (existing order kept). Prints updated, unchanged
# or "skipped: invalid JSON" (file left alone); never fails on bad input.
set -euo pipefail

settings="${1:?usage: claude-merge-settings.sh SETTINGS_JSON BASELINE_JSON}"
baseline="${2:?usage: claude-merge-settings.sh SETTINGS_JSON BASELINE_JSON}"

# Edit a symlink's target, not the link.
if [ -L "$settings" ]; then
	settings="$(readlink "$settings")"
	case "$settings" in /*) ;; *) settings="$(dirname "$1")/$settings" ;; esac
fi

dir="$(dirname "$settings")"
mkdir -p "$dir"
[ -e "$settings" ] || printf '{}\n' >"$settings"

# shellcheck disable=SC2016  # jq program
merge='
	. as $s | $b[0] as $b
	| ($s.enabledPlugins // {}) as $ep
	| ($s.permissions.allow // []) as $allow
	| .statusLine = $b.statusLine
	| .enabledPlugins = ($ep + ($b.enabledPlugins // {} | with_entries(select(.key as $k | $ep | has($k) | not))))
	| .permissions.allow = (reduce ($b.permissions.allow // [])[] as $x ($allow; if any(.[]; . == $x) then . else . + [$x] end))
'

tmp="$(mktemp "$dir/.settings.json.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
if ! jq -e 'type == "object"' "$settings" >/dev/null 2>&1 ||
	! jq --slurpfile b "$baseline" "$merge" "$settings" >"$tmp" 2>/dev/null; then
	echo "skipped: invalid JSON"
	exit 0
fi

if [ "$(jq -c . "$settings")" = "$(jq -c . "$tmp")" ]; then
	echo unchanged
	exit 0
fi

mode="$(stat -c %a "$settings" 2>/dev/null || stat -f %Lp "$settings")"
chmod "$mode" "$tmp"
mv "$tmp" "$settings"
echo updated
