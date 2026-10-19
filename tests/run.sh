#!/usr/bin/env bash
# Run tests/*.test.sh (or those whose basename matches GLOB), one bash process
# each so a failing test can't leak state into the next. Non-zero if any fail.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
glob="${1:-*}"
fail=0
ran=0
for t in "$dir"/*.test.sh; do
	[ -f "$t" ] || continue
	name="$(basename "$t")"
	# shellcheck disable=SC2254  # GLOB is intentionally a pattern
	case "$name" in $glob) ;; *) continue ;; esac
	ran=$((ran + 1))
	if bash "$t"; then
		echo "PASS $name"
	else
		echo "FAIL $name"
		fail=1
	fi
done
if [ "$ran" -eq 0 ]; then
	echo "no tests matched '$glob'" >&2
	exit 1
fi
exit "$fail"
