#!/usr/bin/env bash
# Usage: check-lock.sh LOCKFILE [EXCEPTIONS_FILE]
#
# Gates a mise.lock: every tool needs a checksum for each locked platform, so a
# fresh machine never installs something unverified. Exceptions (tools with no
# upstream build for a platform) must be listed, and an exception that is no
# longer needed fails too, so the list cannot rot.
#
# Output lines (a contract; other scripts and tests match them):
#   MISSING X P           tool X has no checksum for platform P and no exception
#   STALE-EXCEPTION X P   exception for X P, but the checksum is present
# Exceptions file: one `tool-key platform  # reason` per line, tool-key exactly
# as written in the lock; platform `*` means all of them. Exit 0 ok, 1 problems.
# A line without a platform or a `# reason` is rejected (exit 2).
set -uo pipefail

lock="${1:-}"
exceptions="${2:-}"
if [ -z "$lock" ] || [ ! -f "$lock" ]; then
	echo "usage: check-lock.sh LOCKFILE [EXCEPTIONS_FILE]" >&2
	exit 2
fi

# One "tool<TAB>platform<TAB>true|false" row per tool/platform. A tool is
# covered only if every [[tools.X]] element has the checksum (a tool can appear
# more than once); a lone table is treated as a single element.
# shellcheck disable=SC2016  # $k/$els/$p are yq variables, not shell
rows="$(yq -p toml -o tsv '
	.tools // {} | to_entries | .[] | .key as $k |
	((.value | select(tag == "!!seq")) // [.value]) as $els |
	("macos-arm64", "linux-x64", "linux-arm64") as $p |
	[$k, $p, ($els | map(.["platforms." + $p].checksum != null) | all)]
' "$lock")" || {
	echo "check-lock: cannot parse $lock" >&2
	exit 2
}

# Exceptions as "tool<TAB>platform" lines: drop comments and blank lines.
exc=""
if [ -n "$exceptions" ]; then
	[ -f "$exceptions" ] || {
		echo "check-lock: no such exceptions file: $exceptions" >&2
		exit 2
	}
	# Every non-comment line must be `tool platform  # reason`; anything else is
	# a hard error rather than a silently ignored (or silently broad) entry.
	bad="$(awk '
		/^[[:space:]]*(#|$)/ { next }
		{
			line = $0; reason = ""
			if (match(line, /#/)) { reason = substr(line, RSTART + 1); line = substr(line, 1, RSTART - 1) }
			n = split(line, f, /[[:space:]]+/); fields = 0
			for (i = 1; i <= n; i++) if (f[i] != "") fields++
			if (fields < 2) print FILENAME ":" FNR ": missing platform: " $0
			else if (reason !~ /[^[:space:]]/) print FILENAME ":" FNR ": missing # reason: " $0
		}' "$exceptions")"
	if [ -n "$bad" ]; then
		echo "check-lock: malformed exception line (need 'tool platform  # reason'):" >&2
		echo "$bad" >&2
		exit 2
	fi
	exc="$(sed -e 's/#.*//' "$exceptions" | awk 'NF >= 2 { print $1 "\t" $2 }')"
fi

has_exception() { # tool platform
	printf '%s\n' "$exc" | grep -qxF -e "$1"$'\t'"$2" -e "$1"$'\t*'
}

status=0
while IFS=$'\t' read -r tool plat ok; do
	[ -n "$tool" ] || continue
	if [ "$ok" = false ] && ! has_exception "$tool" "$plat"; then
		echo "MISSING $tool $plat"
		status=1
	fi
done <<<"$rows"

# An exception is stale when everything it covers already has a checksum
# (for `*`: all platforms) or the tool is not in the lock at all.
while IFS=$'\t' read -r tool plat; do
	[ -n "$tool" ] || continue
	covered="$(awk -F'\t' -v t="$tool" -v p="$plat" \
		'$1 == t && (p == "*" || $2 == p) { n++; if ($3 == "false") miss++ } END { print n + 0, miss + 0 }' <<<"$rows")"
	n="${covered% *}"
	miss="${covered#* }"
	if [ "$n" -eq 0 ] || [ "$miss" -eq 0 ]; then
		echo "STALE-EXCEPTION $tool $plat"
		status=1
	fi
done <<<"$exc"

exit "$status"
