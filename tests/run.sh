#!/usr/bin/env bash
# Usage: run.sh [REGEX]   e.g. `run.sh env`, `run.sh 'mise-render|lock-sync'`
# Run tests/*.test.sh whose name (basename minus .test.sh) matches the extended
# regex REGEX (default: all). The regex is unanchored, so `glass` also matches
# `iglass-themes`; use `^name$` for an exact selection. TESTS_DIR overrides the
# test dir. One bash process each so a failing test can't leak state into the next. Non-zero if any fail.
set -uo pipefail

dir="${TESTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
pattern="${1:-.}"
fail=0
ran=0
for t in "$dir"/*.test.sh; do
	[ -f "$t" ] || continue
	name="$(basename "$t")"
	grep -Eq -- "$pattern" <<<"${name%.test.sh}" || continue
	ran=$((ran + 1))
	if bash "$t"; then
		echo "PASS $name"
	else
		echo "FAIL $name"
		fail=1
	fi
done
if [ "$ran" -eq 0 ]; then
	echo "no tests matched '$pattern'" >&2
	exit 1
fi
exit "$fail"
