#!/usr/bin/env sh
# Assert every canonical tool binary resolves, runs, and meets its version floor.
# Usage: .github/scripts/assert-tools.sh [path/to/group_vars/all.yml]
# Reads the tool list + overrides from group_vars so there is one source of truth.
set -eu

VARS="${1:-ansible/group_vars/all.yml}"
export PATH="$HOME/.local/bin:$PATH"

command -v yq >/dev/null 2>&1 || {
	echo "FAIL: yq not on PATH (provision did not install it)"
	exit 1
}

# $1 >= $2  (semantic version compare via sort -V)
vge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# Tools with no ubi binary (source-only, e.g. cava) are best-effort: installed
# only where a native package or brew exists, and deliberately skipped on no-sudo
# Linux. They are not a hard requirement, so exempt them from the assertion.
ubi_unavailable=" $(yq '.ubi_unavailable // [] | .[]' "$VARS" | tr '\n' ' ') "

fail=0
for tool in $(yq '.tools[]' "$VARS"); do
	case "$ubi_unavailable" in
	*" $tool "*)
		echo "SKIP: $tool (ubi_unavailable — optional, platform-conditional)"
		continue
		;;
	esac
	bin="$(yq ".ubi_exe_overrides.\"$tool\" // \"$tool\"" "$VARS")"

	if ! command -v "$bin" >/dev/null 2>&1; then
		echo "FAIL: $tool -> '$bin' not found on PATH"
		fail=1
		continue
	fi
	if ! out="$("$bin" --version 2>&1)"; then
		echo "FAIL: $tool -> '$bin' did not run '--version': $(printf '%s' "$out" | head -n1)"
		fail=1
		continue
	fi

	floor="$(yq ".min_versions.\"$tool\" // \"\"" "$VARS")"
	if [ -n "$floor" ]; then
		have="$("$bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
		if [ -z "$have" ] || ! vge "$have" "$floor"; then
			echo "FAIL: $tool -> '$bin' version '${have:-?}' below floor '$floor'"
			fail=1
			continue
		fi
		echo "OK:   $tool -> $bin ($have >= $floor)"
	else
		echo "OK:   $tool -> $bin"
	fi
done

[ "$fail" -eq 0 ] && echo "All tool assertions passed." || echo "Tool assertions FAILED."
exit "$fail"
