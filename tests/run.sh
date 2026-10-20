#!/usr/bin/env bash
# Usage: run.sh [REGEX] — run tests/*.test.sh whose name matches REGEX
# (unanchored ERE; default all), each in its own bash. TESTS_DIR overrides
# the dir. Exits non-zero if any test fails.
set -uo pipefail

# A git hook's GIT_DIR etc. would aim tests' temp-repo git at the real repo.
if command -v git >/dev/null 2>&1; then
	for _v in $(git rev-parse --local-env-vars); do unset "$_v"; done
fi

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
